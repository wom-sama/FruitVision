using System.Diagnostics;
using System.Text;
using System.Text.Json;
using Microsoft.Extensions.Options;

namespace FruitVision.Api.Auth;

public interface IFaceEngine
{
    bool IsReady { get; }
    Task<double[]> ExtractAsync(string imageBase64, CancellationToken cancellationToken);
}
public sealed class FaceOptions
{
    public string NodePath { get; set; } = "";
    public string WorkerPath { get; set; } = "";
}
public sealed class FaceEngineException(int statusCode, string code) : Exception("Face processing did not complete.")
{
    public int StatusCode { get; } = statusCode;
    public string Code { get; } = code;
}
public sealed class FaceEngine(IOptions<FaceOptions> options) : IFaceEngine, IDisposable
{
    public const string ModelSha256 = "0ba9fbfa01b5270c96627c4ef784da859931e02f04419c829e83484087c34e79";
    public const int MaximumImageCharacters = 2796204;
    private readonly SemaphoreSlim inference = new(1, 1);
    private int pending;
    public bool IsReady
    {
        get
        {
            var value = options.Value;
            if (!AbsoluteFile(value.NodePath) || !AbsoluteFile(value.WorkerPath)) return false;
            var directory = Path.GetDirectoryName(value.WorkerPath)!;
            return File.Exists(Path.Combine(directory, "models", "face_detection_yunet_2026may.onnx")) &&
                File.Exists(Path.Combine(directory, "models", "face_recognition_sface_2021dec.onnx")) &&
                File.Exists(Path.Combine(directory, "node_modules", "onnxruntime-node", "package.json")) &&
                File.Exists(Path.Combine(directory, "node_modules", "sharp", "package.json"));
        }
    }
    private static bool AbsoluteFile(string value) => Path.IsPathFullyQualified(value) && File.Exists(value);
    internal static double[] Normalize(double[] values)
    {
        if (values.Length != 128 || values.Any(value => !double.IsFinite(value))) throw new FaceEngineException(422, "FACE_TEMPLATE_INVALID");
        var norm = Math.Sqrt(values.Sum(value => value * value));
        if (!double.IsFinite(norm) || norm < 1e-12) throw new FaceEngineException(422, "FACE_TEMPLATE_INVALID");
        return values.Select(value => value / norm).ToArray();
    }
    public async Task<double[]> ExtractAsync(string imageBase64, CancellationToken cancellationToken)
    {
        if (!IsReady) throw new FaceEngineException(503, "FACE_SERVICE_UNAVAILABLE");
        if (Interlocked.Increment(ref pending) > 3)
        { Interlocked.Decrement(ref pending); throw new FaceEngineException(429, "FACE_SERVICE_BUSY"); }
        var entered = false;
        try
        {
            await inference.WaitAsync(cancellationToken); entered = true;
            using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            deadline.CancelAfter(TimeSpan.FromSeconds(20));
            return await RunAsync(imageBase64, deadline.Token);
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        { throw new FaceEngineException(503, "FACE_SERVICE_UNAVAILABLE"); }
        catch (Exception exception) when (exception is IOException or InvalidDataException or JsonException or InvalidOperationException or System.ComponentModel.Win32Exception)
        { throw new FaceEngineException(503, "FACE_SERVICE_UNAVAILABLE"); }
        finally { if (entered) inference.Release(); Interlocked.Decrement(ref pending); }
    }
    private async Task<double[]> RunAsync(string imageBase64, CancellationToken ct)
    {
        var value = options.Value;
        var start = new ProcessStartInfo(value.NodePath)
        {
            UseShellExecute = false, CreateNoWindow = true, RedirectStandardInput = true,
            RedirectStandardOutput = true, RedirectStandardError = true, StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8, WorkingDirectory = Path.GetDirectoryName(value.WorkerPath)!
        };
        start.ArgumentList.Add("--max-old-space-size=128"); start.ArgumentList.Add(value.WorkerPath);
        start.Environment.Clear();
        foreach (var name in new[] { "SystemRoot", "WINDIR", "TEMP", "TMP", "SystemDrive" })
            if (Environment.GetEnvironmentVariable(name) is { } setting) start.Environment[name] = setting;
        start.Environment["PATH"] = string.Join(Path.PathSeparator, Path.GetDirectoryName(value.NodePath), Environment.GetFolderPath(Environment.SpecialFolder.System));
        start.Environment["UV_THREADPOOL_SIZE"] = "1"; start.Environment["VIPS_CONCURRENCY"] = "1";
        start.Environment["OMP_NUM_THREADS"] = "1"; start.Environment["MKL_NUM_THREADS"] = "1";
        using var process = new Process { StartInfo = start };
        if (!process.Start()) throw new FaceEngineException(503, "FACE_SERVICE_UNAVAILABLE");
        using var stop = ct.Register(() => Kill(process));
        var output = ReadAsync(process.StandardOutput, 32768, process, ct);
        var errors = ReadAsync(process.StandardError, 8192, process, ct, discard: true);
        try
        {
            await JsonSerializer.SerializeAsync(process.StandardInput.BaseStream, new { imageBase64 }, cancellationToken: ct);
            await process.StandardInput.BaseStream.FlushAsync(ct); process.StandardInput.Close();
            await process.WaitForExitAsync(ct);
            var json = await output; await errors;
            using var document = JsonDocument.Parse(json, new JsonDocumentOptions { MaxDepth = 4 });
            var root = document.RootElement;
            if (root.TryGetProperty("error", out var error))
            {
                var code = error.GetString();
                var status = code switch
                {
                    "FACE_REQUEST_INVALID" => 400,
                    "FACE_IMAGE_INVALID" or "FACE_NOT_FOUND" or "FACE_MULTIPLE_FACES" or "FACE_IMAGE_QUALITY" or "FACE_TEMPLATE_INVALID" => 422,
                    "FACE_SERVICE_BUSY" => 429,
                    _ => 503
                };
                throw new FaceEngineException(status, status == 503 ? "FACE_SERVICE_UNAVAILABLE" : code!);
            }
            if (process.ExitCode != 0 || root.EnumerateObject().Count() != 1 || !root.TryGetProperty("embedding", out var embedding))
                throw new FaceEngineException(503, "FACE_SERVICE_UNAVAILABLE");
            var values = embedding.Deserialize<double[]>() ?? throw new JsonException();
            var normalized = Normalize(values);
            if (Math.Abs(Math.Sqrt(values.Sum(number => number * number)) - 1) > .00001)
                throw new FaceEngineException(503, "FACE_SERVICE_UNAVAILABLE");
            return normalized;
        }
        finally
        {
            Kill(process);
            try { await process.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(2)); }
            catch (Exception exception) when (exception is InvalidOperationException or TimeoutException) { }
            try { await Task.WhenAll(output, errors).WaitAsync(TimeSpan.FromSeconds(2)); }
            catch (Exception exception) when (exception is OperationCanceledException or IOException or InvalidDataException or TimeoutException) { }
        }
    }
    private static async Task<string> ReadAsync(StreamReader reader, int maximum, Process process, CancellationToken ct, bool discard = false)
    {
        var buffer = new char[1024]; var text = new StringBuilder(); var count = 0;
        while (true)
        {
            var read = await reader.ReadAsync(buffer.AsMemory(), ct); if (read == 0) break;
            count += read;
            if (count > maximum) { Kill(process); throw new InvalidDataException("Face worker protocol exceeded its limit."); }
            if (!discard) text.Append(buffer, 0, read);
        }
        return text.ToString();
    }
    private static void Kill(Process process)
    {
        try { if (!process.HasExited) process.Kill(entireProcessTree: true); }
        catch (Exception exception) when (exception is InvalidOperationException or System.ComponentModel.Win32Exception) { }
    }
    public void Dispose() => inference.Dispose();
}
public static class FaceRegistration
{
    public static IServiceCollection AddFaceAuth(this IServiceCollection services, IConfiguration configuration)
    {
        services.Configure<FaceOptions>(configuration.GetSection("Face"));
        services.AddSingleton<IFaceEngine, FaceEngine>();
        return services;
    }
}
