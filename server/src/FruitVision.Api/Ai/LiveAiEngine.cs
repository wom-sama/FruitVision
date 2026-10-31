using System.Diagnostics;
using System.Text;
using System.Text.Json;
using System.Text.Encodings.Web;
using Microsoft.Extensions.Options;

namespace FruitVision.Api.Ai;

public sealed record LiveAiObject(double[] Box, double Score, string FruitLabel, int StageCode, string StageLabel);
public sealed record LiveAiFrameResult(int ImageWidth, int ImageHeight, IReadOnlyList<LiveAiObject> Objects, double ProcessingMs);
public interface ILiveAiEngine
{
    bool IsReady { get; }
    Task StartAsync(CancellationToken cancellationToken);
    Task<LiveAiFrameResult> InferAsync(byte[] jpeg, CancellationToken cancellationToken);
    Task StopAsync(CancellationToken cancellationToken);
}
public sealed class LiveAiException(int status, string code) : Exception("Live AI did not complete.")
{
    public int Status { get; } = status;
    public string Code { get; } = code;
}
public sealed class LiveAiEngine(IOptions<AiOptions> ai, IOptions<LiveAiOptions> live, AiRuntimeStatus runtime) : ILiveAiEngine, IDisposable
{
    private Process? process;
    private CancellationTokenSource? lifetime;
    private Task? errors;
    private static readonly JsonSerializerOptions PipeJson = new() { Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping };
    private string WorkerPath => string.IsNullOrWhiteSpace(live.Value.WorkerPath)
        ? Path.Combine(Path.GetDirectoryName(ai.Value.WorkerPath) ?? "", "live_worker.py") : live.Value.WorkerPath;
    public bool IsReady => runtime.IsReady && Path.IsPathFullyQualified(WorkerPath) && File.Exists(WorkerPath);

    public async Task StartAsync(CancellationToken ct)
    {
        if (process is { HasExited: false }) return;
        if (!IsReady) throw new LiveAiException(503, "LIVE_AI_UNAVAILABLE");
        var settings = ai.Value;
        var start = new ProcessStartInfo(settings.PythonPath) { UseShellExecute = false, CreateNoWindow = true,
            RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true,
            StandardInputEncoding = new UTF8Encoding(false), StandardOutputEncoding = Encoding.UTF8, StandardErrorEncoding = Encoding.UTF8,
            WorkingDirectory = Path.GetDirectoryName(WorkerPath)! };
        foreach (var argument in new[] { "-X", "utf8", "-B", WorkerPath }) start.ArgumentList.Add(argument);
        start.Environment.Clear();
        foreach (var name in new[] { "SystemRoot", "WINDIR", "TEMP", "TMP", "SystemDrive" })
            if (Environment.GetEnvironmentVariable(name) is { } value) start.Environment[name] = value;
        start.Environment["PATH"] = string.Join(Path.PathSeparator, Path.GetDirectoryName(settings.PythonPath),
            Path.Combine(settings.PythonModulePath, "onnxruntime", "capi"), Environment.GetFolderPath(Environment.SpecialFolder.System));
        start.Environment["PYTHONPATH"] = string.Join(Path.PathSeparator,
            new[] { settings.PythonModulePath, settings.PythonExtraModulePath }.Where(p => !string.IsNullOrWhiteSpace(p)));
        start.Environment["PYTHONNOUSERSITE"] = "1"; start.Environment["PYTHONUTF8"] = "1"; start.Environment["PYTHONDONTWRITEBYTECODE"] = "1";
        start.Environment["OMP_NUM_THREADS"] = "2"; start.Environment["MKL_NUM_THREADS"] = "2"; start.Environment["OPENBLAS_NUM_THREADS"] = "2";
        start.Environment["FRUITVISION_MODEL_PATH"] = settings.ModelPath;
        process = new Process { StartInfo = start };
        try
        {
            if (!process.Start()) throw new InvalidOperationException();
            lifetime = new CancellationTokenSource(); errors = DrainErrors(process, lifetime.Token);
            using var stop = ct.Register(() => Kill(process));
            using var ready = JsonDocument.Parse(await ReadLine(process.StandardOutput, ct));
            var root = ready.RootElement;
            if (root.GetProperty("type").GetString() != "ready" || root.GetProperty("modelSha256").GetString() != LiveAiRuntime.ModelSha256 ||
                root.GetProperty("scope").GetString() != "predicted-mango-only") throw new InvalidDataException();
        }
        catch (Exception error) when (error is IOException or JsonException or InvalidOperationException or KeyNotFoundException or OperationCanceledException or System.ComponentModel.Win32Exception)
        { await StopAsync(CancellationToken.None); throw new LiveAiException(503, "LIVE_AI_UNAVAILABLE"); }
    }

    public async Task<LiveAiFrameResult> InferAsync(byte[] jpeg, CancellationToken ct)
    {
        var active = process;
        if (active is null || active.HasExited) throw new LiveAiException(503, "LIVE_AI_UNAVAILABLE");
        using var stop = ct.Register(() => Kill(active));
        try
        {
            var id = Guid.NewGuid().ToString("N");
            await JsonSerializer.SerializeAsync(active.StandardInput.BaseStream, new { id, imageBase64 = Convert.ToBase64String(jpeg) }, options: PipeJson, cancellationToken: ct);
            await active.StandardInput.WriteLineAsync(); await active.StandardInput.FlushAsync(ct);
            using var document = JsonDocument.Parse(await ReadLine(active.StandardOutput, ct));
            var root = document.RootElement; var type = root.GetProperty("type").GetString();
            if (type == "error" && root.GetProperty("id").GetString() == id && root.GetProperty("code").GetString() == "LIVE_FRAME_INVALID")
                throw new LiveAiException(422, "LIVE_FRAME_INVALID");
            if (type != "frame" || root.GetProperty("id").GetString() != id) throw new InvalidDataException();
            return new(root.GetProperty("imageWidth").GetInt32(), root.GetProperty("imageHeight").GetInt32(),
                root.GetProperty("objects").Deserialize<LiveAiObject[]>(new JsonSerializerOptions(JsonSerializerDefaults.Web)) ?? throw new JsonException(),
                root.GetProperty("processingMs").GetDouble());
        }
        catch (Exception error) when (error is IOException or JsonException or InvalidOperationException or KeyNotFoundException or FormatException or OperationCanceledException)
        { throw new LiveAiException(503, "LIVE_AI_UNAVAILABLE"); }
    }

    private static async Task<string> ReadLine(StreamReader reader, CancellationToken ct)
    {
        var text = new StringBuilder(); var character = new char[1];
        while (text.Length <= 32768)
        {
            if (await reader.ReadAsync(character.AsMemory(), ct) == 0) throw new InvalidDataException();
            if (character[0] == '\n') return text.ToString();
            text.Append(character[0]);
        }
        throw new InvalidDataException();
    }
    private static async Task DrainErrors(Process child, CancellationToken ct)
    {
        try
        {
            var buffer = new char[1024]; var count = 0;
            while (true) { var size = await child.StandardError.ReadAsync(buffer.AsMemory(), ct); if (size == 0) break; count += size; if (count > 8192) { Kill(child); break; } }
        }
        catch (Exception error) when (error is IOException or OperationCanceledException or ObjectDisposedException) { }
    }
    private static void Kill(Process? child)
    { try { if (child is not null && !child.HasExited) child.Kill(entireProcessTree: true); } catch (Exception error) when (error is InvalidOperationException or System.ComponentModel.Win32Exception) { } }
    public async Task StopAsync(CancellationToken ct)
    {
        var child = process; process = null; lifetime?.Cancel(); Kill(child);
        if (child is not null)
        { try { await child.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(2), ct); } catch (Exception error) when (error is InvalidOperationException or TimeoutException or OperationCanceledException) { } child.Dispose(); }
        if (errors is not null) { try { await errors.WaitAsync(TimeSpan.FromSeconds(2), ct); } catch (Exception error) when (error is TimeoutException or OperationCanceledException) { } }
        lifetime?.Dispose(); lifetime = null; errors = null;
    }
    public void Dispose() { Kill(process); lifetime?.Cancel(); process?.Dispose(); lifetime?.Dispose(); }
}
