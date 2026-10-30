using System.Diagnostics;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using FruitVision.Api.Data;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Options;

namespace FruitVision.Api.Ai;

public sealed class AiJobWorker(IServiceScopeFactory scopes, IOptions<AiOptions> options,
    AiRuntimeStatus runtime, AiStorage storage, AiJobControl control, AiJobEvents events,
    ILogger<AiJobWorker> logger) : BackgroundService
{
    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        if (!options.Value.RunEnabled) return;
        using (var scope = scopes.CreateScope())
        {
            var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
            var orphans = await db.Set<AiJob>().AsNoTracking().Where(job => job.Status == AiJobStatus.Running).ToListAsync(stoppingToken);
            foreach (var orphan in orphans)
            {
                await events.FinishAsync(orphan.Id, AiJobStatus.Failed, "Máy chủ đã khởi động lại. Hãy gửi một tác vụ mới.", cancellationToken: stoppingToken);
                storage.RemoveInput(orphan);
            }
        }
        if (!runtime.IsReady) { logger.LogWarning("AI processing is disabled because required local assets are unavailable."); return; }
        Guid? pendingFailure = null;
        while (!stoppingToken.IsCancellationRequested)
        {
            AiJob? job = null;
            try
            {
                if (pendingFailure.HasValue)
                {
                    await events.FinishAsync(pendingFailure.Value, AiJobStatus.Failed,
                        "Tác vụ bị gián đoạn khi lưu kết quả. Hãy gửi một tác vụ mới.", cancellationToken: stoppingToken);
                    pendingFailure = null;
                }
                job = await ClaimAsync(stoppingToken);
                if (job is null) { await Task.Delay(750, stoppingToken); continue; }
                await ProcessAsync(job, stoppingToken);
            }
            catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested) { break; }
            catch (Exception exception)
            {
                if (job is not null) pendingFailure = job.Id;
                logger.LogWarning("AI queue iteration failed ({FailureType}).", exception.GetType().Name);
                await Task.Delay(1500, stoppingToken);
            }
        }
    }

    private async Task<AiJob?> ClaimAsync(CancellationToken cancellationToken)
    {
        using var scope = scopes.CreateScope();
        var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
        var job = await db.Set<AiJob>().AsNoTracking().Where(item => item.Status == AiJobStatus.Queued)
            .OrderBy(item => item.CreatedAt).ThenBy(item => item.Id).FirstOrDefaultAsync(cancellationToken);
        if (job is null) return null;
        if (!await db.Users.AnyAsync(user => user.Id == job.UserId && user.IsActive &&
            user.ApprovalStatus == ApprovalState.Approved, cancellationToken))
        {
            await events.FinishAsync(job.Id, AiJobStatus.Cancelled, cancellationToken: cancellationToken);
            storage.RemoveInput(job);
            return null;
        }
        var changed = await db.Set<AiJob>().Where(item => item.Id == job.Id && item.Status == AiJobStatus.Queued)
            .ExecuteUpdateAsync(update => update.SetProperty(item => item.Status, AiJobStatus.Running)
                .SetProperty(item => item.Revision, item => item.Revision + 1), cancellationToken);
        if (changed == 0) return null;
        job.Status = AiJobStatus.Running;
        job.Revision++;
        await events.PublishAsync(job, cancellationToken);
        return job;
    }

    private async Task ProcessAsync(AiJob job, CancellationToken stoppingToken)
    {
        using var jobCancellation = CancellationTokenSource.CreateLinkedTokenSource(stoppingToken);
        jobCancellation.CancelAfter(TimeSpan.FromSeconds(180));
        control.Track(job.Id, jobCancellation);
        using var monitorStop = CancellationTokenSource.CreateLinkedTokenSource(stoppingToken);
        var monitor = MonitorAsync(job, jobCancellation, monitorStop.Token);
        try
        {
            if (!await StillAuthorizedAsync(job, stoppingToken))
            { await events.FinishAsync(job.Id, AiJobStatus.Cancelled); return; }
            var directory = storage.DirectoryFor(job.Id);
            var input = storage.InputFor(job);
            if (!File.Exists(input) || (File.GetAttributes(input) & FileAttributes.ReparsePoint) != 0)
                throw new InvalidDataException("Missing private input.");
            var jobFile = Path.Combine(directory, "job.json");
            await File.WriteAllTextAsync(jobFile, JsonSerializer.Serialize(new
            { id = job.Id, mediaType = job.MediaType, inputPath = input, outputDirectory = directory }), jobCancellation.Token);
            var result = await RunWorkerAsync(job, jobFile, jobCancellation.Token);
            var previewAvailable = false;
            if (result.PreviewPath is not null)
            {
                var expected = storage.PreviewFor(job.Id);
                if (!string.Equals(Path.GetFullPath(result.PreviewPath), expected,
                    OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal))
                    throw new InvalidDataException("Unexpected preview location.");
                await using var preview = storage.OpenPreview(job.Id);
                previewAvailable = preview is not null;
                if (!previewAvailable) throw new InvalidDataException("Invalid preview.");
            }
            await events.FinishAsync(job.Id, AiJobStatus.Succeeded, result: result.ResultJson, preview: previewAvailable);
        }
        catch (OperationCanceledException)
        {
            var authorized = !stoppingToken.IsCancellationRequested && await StillAuthorizedAsync(job, CancellationToken.None);
            await events.FinishAsync(job.Id, authorized ? AiJobStatus.Failed : AiJobStatus.Cancelled,
                authorized ? "Tác vụ vượt quá thời gian xử lý cho phép." : null);
        }
        catch (Exception exception)
        {
            logger.LogWarning("AI job {JobId} failed ({FailureType}).", job.Id, exception.GetType().Name);
            await events.FinishAsync(job.Id, AiJobStatus.Failed, "Không thể phân tích tệp này. Hãy kiểm tra ảnh hoặc video và thử lại.");
        }
        finally
        {
            control.Untrack(job.Id);
            monitorStop.Cancel();
            try { await monitor; } catch (OperationCanceledException) { }
            storage.RemoveInput(job);
        }
    }

    private async Task<bool> StillAuthorizedAsync(AiJob job, CancellationToken cancellationToken)
    {
        using var scope = scopes.CreateScope();
        var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
        return await db.Set<AiJob>().AnyAsync(item => item.Id == job.Id && item.Status == AiJobStatus.Running, cancellationToken) &&
            await db.Users.AnyAsync(user => user.Id == job.UserId && user.IsActive &&
                user.ApprovalStatus == ApprovalState.Approved, cancellationToken);
    }

    private async Task MonitorAsync(AiJob job, CancellationTokenSource jobCancellation, CancellationToken cancellationToken)
    {
        try
        {
            while (!cancellationToken.IsCancellationRequested)
            {
                await Task.Delay(750, cancellationToken);
                if (!await StillAuthorizedAsync(job, cancellationToken)) { jobCancellation.Cancel(); return; }
            }
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { }
        catch (Exception exception)
        {
            logger.LogWarning("AI job {JobId} permission monitor stopped ({FailureType}).", job.Id, exception.GetType().Name);
            jobCancellation.Cancel();
        }
    }

    private ProcessStartInfo StartInfo(string jobFile)
    {
        var value = options.Value;
        var start = new ProcessStartInfo(value.PythonPath)
        {
            UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true,
            RedirectStandardError = true, StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8, WorkingDirectory = Path.GetDirectoryName(value.WorkerPath)!
        };
        foreach (var argument in new[] { "-X", "utf8", "-B", value.WorkerPath, "--job", jobFile }) start.ArgumentList.Add(argument);
        // Do not pass API/database/tunnel credentials from the parent environment to a decoder process.
        start.Environment.Clear();
        foreach (var name in new[] { "SystemRoot", "WINDIR", "TEMP", "TMP", "SystemDrive" })
            if (Environment.GetEnvironmentVariable(name) is { } setting) start.Environment[name] = setting;
        start.Environment["PATH"] = string.Join(Path.PathSeparator, new[] {
            Path.GetDirectoryName(value.PythonPath), Path.Combine(value.PythonModulePath, "onnxruntime", "capi"),
            Environment.GetFolderPath(Environment.SpecialFolder.System) });
        start.Environment["PYTHONPATH"] = value.PythonModulePath;
        if (Path.IsPathFullyQualified(value.PythonExtraModulePath) && Directory.Exists(value.PythonExtraModulePath))
            start.Environment["PYTHONPATH"] += Path.PathSeparator + value.PythonExtraModulePath;
        start.Environment["PYTHONNOUSERSITE"] = "1";
        start.Environment["PYTHONUTF8"] = "1";
        start.Environment["PYTHONDONTWRITEBYTECODE"] = "1";
        start.Environment["OMP_NUM_THREADS"] = "2";
        start.Environment["MKL_NUM_THREADS"] = "2";
        start.Environment["FRUITVISION_MODEL_PATH"] = value.ModelPath;
        return start;
    }

    private async Task<WorkerResult> RunWorkerAsync(AiJob job, string jobFile, CancellationToken cancellationToken)
    {
        using var process = new Process { StartInfo = StartInfo(jobFile) };
        if (!process.Start()) throw new InvalidOperationException("Worker did not start.");
        using var killOnCancellation = cancellationToken.Register(() => KillOwned(process));
        var output = ReadOutputAsync(process.StandardOutput, job, cancellationToken);
        var stderr = DrainErrorAsync(process.StandardError, cancellationToken);
        try
        {
            var result = await output;
            await process.WaitForExitAsync(cancellationToken);
            var errorSummary = await stderr;
            if (process.ExitCode != 0 || result is null)
            {
                logger.LogWarning("AI worker {JobId} exited {ExitCode}; stderr length {StderrLength}, fingerprint {Fingerprint}.",
                    job.Id, process.ExitCode, errorSummary.Length, errorSummary.Fingerprint);
                throw new InvalidDataException("Worker failed or omitted a result.");
            }
            return result;
        }
        finally
        {
            KillOwned(process);
            try { await process.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(5)); }
            catch (Exception exception) when (exception is InvalidOperationException or TimeoutException) { }
            try { await Task.WhenAll(output, stderr).WaitAsync(TimeSpan.FromSeconds(5)); }
            catch (Exception exception) when (exception is IOException or OperationCanceledException or TimeoutException or InvalidDataException or JsonException) { }
        }
    }

    private static void KillOwned(Process process)
    {
        try { if (!process.HasExited) process.Kill(entireProcessTree: true); }
        catch (Exception exception) when (exception is InvalidOperationException or System.ComponentModel.Win32Exception) { }
    }

    private async Task<WorkerResult?> ReadOutputAsync(StreamReader reader, AiJob job, CancellationToken cancellationToken)
    {
        var buffer = new char[4096];
        var line = new StringBuilder();
        var total = 0;
        var messages = 0;
        WorkerResult? result = null;
        var lastProgress = Stopwatch.StartNew();
        while (true)
        {
            var count = await reader.ReadAsync(buffer.AsMemory(), cancellationToken);
            if (count == 0) break;
            total += count;
            if (total > 8 * 1024 * 1024) throw new InvalidDataException("Worker output limit exceeded.");
            for (var index = 0; index < count; index++)
            {
                var character = buffer[index];
                if (character == '\r') continue;
                if (character != '\n')
                {
                    if (line.Length >= 256 * 1024) throw new InvalidDataException("Worker line limit exceeded.");
                    line.Append(character);
                    continue;
                }
                if (line.Length == 0) continue;
                if (++messages > 5000 || result is not null) throw new InvalidDataException("Unexpected worker output.");
                using var document = JsonDocument.Parse(line.ToString(), new JsonDocumentOptions { MaxDepth = 32 });
                line.Clear();
                var message = document.RootElement;
                switch (message.GetProperty("type").GetString())
                {
                    case "progress":
                        var progress = message.GetProperty("progress").GetInt32();
                        var frames = message.GetProperty("framesProcessed").GetInt32();
                        if (progress is < 0 or > 99 || frames is < 0 or > 1000000) throw new InvalidDataException("Invalid progress.");
                        if (lastProgress.ElapsedMilliseconds >= 300 || progress == 99)
                        {
                            await ProgressAsync(job.Id, progress, frames, cancellationToken);
                            lastProgress.Restart();
                        }
                        break;
                    case "completed":
                        var body = message.GetProperty("result");
                        if (body.ValueKind != JsonValueKind.Object || body.GetRawText().Length > 192 * 1024)
                            throw new InvalidDataException("Invalid result.");
                        var grades = body.GetProperty("gradeCounts");
                        foreach (var grade in new[] { "Xanh / chưa chín", "Chín", "Chưa xác định" })
                            if (grades.GetProperty(grade).GetInt32() is < 0 or > 1000000) throw new InvalidDataException("Invalid grade count.");
                        result = new WorkerResult(body.GetRawText(), message.TryGetProperty("previewPath", out var path) &&
                            path.ValueKind == JsonValueKind.String ? path.GetString() : null);
                        break;
                    default: throw new InvalidDataException("Worker rejected input or sent an unknown event.");
                }
            }
        }
        if (line.Length != 0) throw new InvalidDataException("Incomplete worker event.");
        return result;
    }

    private async Task ProgressAsync(Guid id, int progress, int frames, CancellationToken cancellationToken)
    {
        using var scope = scopes.CreateScope();
        var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
        var changed = await db.Set<AiJob>().Where(job => job.Id == id && job.Status == AiJobStatus.Running &&
            job.Progress <= progress && job.FramesProcessed <= frames && (job.Progress < progress || job.FramesProcessed < frames))
            .ExecuteUpdateAsync(update => update.SetProperty(job => job.Progress, progress).SetProperty(job => job.FramesProcessed, frames)
                .SetProperty(job => job.Revision, job => job.Revision + 1), cancellationToken);
        if (changed != 0)
        {
            var job = await db.Set<AiJob>().AsNoTracking().SingleAsync(item => item.Id == id, cancellationToken);
            await events.PublishAsync(job, cancellationToken);
        }
    }

    private static async Task<(int Length, string Fingerprint)> DrainErrorAsync(StreamReader reader, CancellationToken cancellationToken)
    {
        var buffer = new char[2048];
        var retained = new StringBuilder();
        var total = 0;
        while (true)
        {
            var count = await reader.ReadAsync(buffer.AsMemory(), cancellationToken);
            if (count == 0) break;
            total += count;
            if (total > 1024 * 1024) throw new InvalidDataException("Worker stderr limit exceeded.");
            if (retained.Length < 8192) retained.Append(buffer, 0, Math.Min(count, 8192 - retained.Length));
        }
        return (total, Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(retained.ToString())))[..16]);
    }

    private sealed record WorkerResult(string ResultJson, string? PreviewPath);
}
