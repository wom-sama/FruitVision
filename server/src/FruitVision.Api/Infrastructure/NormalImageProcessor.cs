using System.Diagnostics;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using FruitVision.Api.Ai;
using FruitVision.Api.Data;
using Microsoft.Extensions.Options;

namespace FruitVision.Api.Infrastructure;

public sealed record ProcessedNormalImage(int Width, int Height, long SizeBytes, string Sha256);
public interface INormalImageProcessor
{
    bool IsReady { get; }
    Task<ProcessedNormalImage> ProcessAsync(string inputPath, string outputPath, CancellationToken cancellationToken);
}
public sealed class NormalImageException(int statusCode, string code) : Exception("Image processing did not complete.")
{
    public int StatusCode { get; } = statusCode;
    public string Code { get; } = code;
}
public sealed class NormalMediaOptions
{
    public const long MaximumBytes = 5L * 1024 * 1024;
    public string RootPath { get; set; } = "";
    public string WorkerPath { get; set; } = "";
}
public sealed class NormalImageProcessor(IOptions<NormalMediaOptions> options, IOptions<AiOptions> ai) : INormalImageProcessor, IDisposable
{
    private readonly SemaphoreSlim processing = new(1, 1);
    private int pending;
    private string WorkerPath => string.IsNullOrWhiteSpace(options.Value.WorkerPath)
        ? Path.Combine(Path.GetDirectoryName(ai.Value.WorkerPath) ?? "", "sanitize_shared_image.py") : options.Value.WorkerPath;
    public bool IsReady => Path.IsPathFullyQualified(ai.Value.PythonPath) && File.Exists(ai.Value.PythonPath) &&
        Path.IsPathFullyQualified(WorkerPath) && File.Exists(WorkerPath) &&
        new[] { ai.Value.PythonModulePath, ai.Value.PythonExtraModulePath }.Where(p => !string.IsNullOrWhiteSpace(p))
            .Any(p => Path.IsPathFullyQualified(p) && File.Exists(Path.Combine(p, "PIL", "__init__.py")));
    public async Task<ProcessedNormalImage> ProcessAsync(string inputPath, string outputPath, CancellationToken cancellationToken)
    {
        if (!IsReady) throw new NormalImageException(503, "IMAGE_PROCESSOR_UNAVAILABLE");
        if (Interlocked.Increment(ref pending) > 3) { Interlocked.Decrement(ref pending); throw new NormalImageException(429, "IMAGE_PROCESSOR_BUSY"); }
        var entered = false;
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        deadline.CancelAfter(TimeSpan.FromSeconds(20));
        try
        {
            await processing.WaitAsync(deadline.Token); entered = true;
            return await RunAsync(inputPath, outputPath, deadline.Token);
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested) { throw new NormalImageException(503, "IMAGE_PROCESSOR_UNAVAILABLE"); }
        catch (Exception e) when (e is IOException or JsonException or InvalidOperationException or KeyNotFoundException or FormatException or System.ComponentModel.Win32Exception)
        { throw new NormalImageException(503, "IMAGE_PROCESSOR_UNAVAILABLE"); }
        finally { if (entered) processing.Release(); Interlocked.Decrement(ref pending); }
    }
    private async Task<ProcessedNormalImage> RunAsync(string inputPath, string outputPath, CancellationToken ct)
    {
        var start = new ProcessStartInfo(ai.Value.PythonPath) { UseShellExecute = false, CreateNoWindow = true,
            RedirectStandardOutput = true, RedirectStandardError = true, StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8, WorkingDirectory = Path.GetDirectoryName(WorkerPath)! };
        foreach (var value in new[] { "-X", "utf8", "-B", WorkerPath, "--input", inputPath, "--output", outputPath }) start.ArgumentList.Add(value);
        start.Environment.Clear();
        foreach (var name in new[] { "SystemRoot", "WINDIR", "TEMP", "TMP", "SystemDrive" })
            if (Environment.GetEnvironmentVariable(name) is { } value) start.Environment[name] = value;
        start.Environment["PATH"] = string.Join(Path.PathSeparator, Path.GetDirectoryName(ai.Value.PythonPath), Environment.GetFolderPath(Environment.SpecialFolder.System));
        start.Environment["PYTHONPATH"] = string.Join(Path.PathSeparator, new[] { ai.Value.PythonModulePath, ai.Value.PythonExtraModulePath }.Where(p => !string.IsNullOrWhiteSpace(p)));
        start.Environment["OMP_NUM_THREADS"] = "1"; start.Environment["MKL_NUM_THREADS"] = "1"; start.Environment["OPENBLAS_NUM_THREADS"] = "1";
        using var process = new Process { StartInfo = start };
        if (!process.Start()) throw new NormalImageException(503, "IMAGE_PROCESSOR_UNAVAILABLE");
        using var stop = ct.Register(() => Kill(process));
        var stdout = Read(process.StandardOutput, process, ct); var stderr = Read(process.StandardError, process, ct, discard: true);
        try
        {
            await process.WaitForExitAsync(ct); var text = await stdout; await stderr;
            using var json = JsonDocument.Parse(text, new JsonDocumentOptions { MaxDepth = 3 });
            var root = json.RootElement;
            if (root.TryGetProperty("error", out var error))
                throw new NormalImageException(error.GetString() == "IMAGE_INVALID" ? 422 : 503,
                    error.GetString() == "IMAGE_INVALID" ? "IMAGE_INVALID" : "IMAGE_PROCESSOR_UNAVAILABLE");
            if (process.ExitCode != 0 || root.EnumerateObject().Count() != 4) throw new InvalidDataException();
            var result = new ProcessedNormalImage(root.GetProperty("width").GetInt32(), root.GetProperty("height").GetInt32(),
                root.GetProperty("sizeBytes").GetInt64(), root.GetProperty("sha256").GetString() ?? "");
            if (result.Width is < 1 or > 2048 || result.Height is < 1 or > 2048 || result.SizeBytes is < 4 or > NormalMediaOptions.MaximumBytes ||
                !File.Exists(outputPath) || (File.GetAttributes(outputPath) & FileAttributes.ReparsePoint) != 0 || new FileInfo(outputPath).Length != result.SizeBytes)
                throw new InvalidDataException();
            await using var file = File.OpenRead(outputPath);
            if (Convert.ToHexString(await SHA256.HashDataAsync(file, ct)).ToLowerInvariant() != result.Sha256) throw new InvalidDataException();
            return result;
        }
        finally
        {
            Kill(process);
            try { await process.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(2)); } catch (Exception e) when (e is InvalidOperationException or TimeoutException) { }
            try { await Task.WhenAll(stdout, stderr).WaitAsync(TimeSpan.FromSeconds(2)); } catch (Exception e) when (e is IOException or OperationCanceledException or TimeoutException) { }
        }
    }
    private static async Task<string> Read(StreamReader reader, Process process, CancellationToken ct, bool discard = false)
    {
        var buffer = new char[1024]; var text = new StringBuilder(); var count = 0;
        while (true)
        {
            var size = await reader.ReadAsync(buffer.AsMemory(), ct); if (size == 0) return text.ToString();
            count += size; if (count > 4096) { Kill(process); throw new InvalidDataException(); }
            if (!discard) text.Append(buffer, 0, size);
        }
    }
    private static void Kill(Process process) { try { if (!process.HasExited) process.Kill(entireProcessTree: true); } catch (Exception e) when (e is InvalidOperationException or System.ComponentModel.Win32Exception) { } }
    public void Dispose() => processing.Dispose();
}

public sealed class NormalMediaStorage(IOptions<NormalMediaOptions> options, IWebHostEnvironment environment, ILogger<NormalMediaStorage> log)
{
    private string Root()
    {
        if (!Path.IsPathFullyQualified(options.Value.RootPath)) throw new NormalImageException(503, "IMAGE_STORAGE_UNAVAILABLE");
        var root = Path.GetFullPath(options.Value.RootPath);
        var webRoot = Path.GetFullPath(environment.WebRootPath ?? Path.Combine(environment.ContentRootPath, "wwwroot"));
        var relative = Path.GetRelativePath(webRoot, root);
        if (relative == "." || (!Path.IsPathRooted(relative) && relative != ".." && !relative.StartsWith(".." + Path.DirectorySeparatorChar, StringComparison.Ordinal)))
            throw new NormalImageException(503, "IMAGE_STORAGE_UNAVAILABLE");
        Directory.CreateDirectory(root);
        if ((File.GetAttributes(root) & FileAttributes.ReparsePoint) != 0) throw new NormalImageException(503, "IMAGE_STORAGE_UNAVAILABLE");
        return root;
    }
    public string Staging(Guid id, string extension)
    {
        var folder = Path.Combine(Root(), ".staging"); Directory.CreateDirectory(folder);
        if ((File.GetAttributes(folder) & FileAttributes.ReparsePoint) != 0) throw new NormalImageException(503, "IMAGE_STORAGE_UNAVAILABLE");
        return Path.Combine(folder, id.ToString("N") + extension);
    }
    public string ImagePath(Guid id) => Path.Combine(Root(), id.ToString("N") + ".jpg");
    public async Task<string> ReceiveAsync(HttpRequest request, string path, CancellationToken ct)
    {
        var type = request.ContentType?.Split(';')[0].Trim().ToLowerInvariant();
        if (type is not ("image/jpeg" or "image/png")) throw new NormalImageException(415, "IMAGE_TYPE_UNSUPPORTED");
        if (request.ContentLength > NormalMediaOptions.MaximumBytes) throw new NormalImageException(413, "IMAGE_TOO_LARGE");
        await using var file = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None, 65536, FileOptions.Asynchronous);
        using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        var buffer = new byte[65536]; var prefix = 0;
        while (prefix < 16)
        {
            var read = await request.Body.ReadAsync(buffer.AsMemory(prefix, 16 - prefix), ct); if (read == 0) break; prefix += read;
        }
        if (!AiStorage.MagicMatches(type, buffer.AsSpan(0, prefix))) throw new NormalImageException(422, "IMAGE_INVALID");
        long total = prefix; hash.AppendData(buffer, 0, prefix); await file.WriteAsync(buffer.AsMemory(0, prefix), ct);
        while (true)
        {
            var read = await request.Body.ReadAsync(buffer.AsMemory(), ct); if (read == 0) break;
            total += read; if (total > NormalMediaOptions.MaximumBytes) throw new NormalImageException(413, "IMAGE_TOO_LARGE");
            hash.AppendData(buffer, 0, read); await file.WriteAsync(buffer.AsMemory(0, read), ct);
        }
        await file.FlushAsync(ct);
        return Convert.ToHexString(hash.GetHashAndReset()).ToLowerInvariant();
    }
    public FileStream? Open(NormalImage image)
    {
        var path = ImagePath(image.Id);
        if (!File.Exists(path) || (File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0) return null;
        var file = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 65536, FileOptions.Asynchronous | FileOptions.SequentialScan);
        Span<byte> magic = stackalloc byte[3];
        if (file.Length != image.SizeBytes || file.Length is < 4 or > NormalMediaOptions.MaximumBytes || file.Read(magic) != 3 || !AiStorage.MagicMatches("image/jpeg", magic))
        { file.Dispose(); return null; }
        file.Position = 0; return file;
    }
    public void Remove(string? path)
    {
        if (path is null) return;
        try { File.Delete(path); } catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        { log.LogWarning("Normal image cleanup failed ({Kind}).", e.GetType().Name); }
    }
}
public static class NormalMediaRegistration
{
    public static IServiceCollection AddNormalMedia(this IServiceCollection services, IConfiguration configuration)
    {
        services.Configure<NormalMediaOptions>(configuration.GetSection("NormalMedia"));
        services.AddSingleton<INormalImageProcessor, NormalImageProcessor>();
        services.AddSingleton<NormalMediaStorage>();
        return services;
    }
}
