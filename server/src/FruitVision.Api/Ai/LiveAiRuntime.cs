using Microsoft.Extensions.DependencyInjection.Extensions;
using Microsoft.Extensions.Options;
using Microsoft.EntityFrameworkCore;
using FruitVision.Api.Data;
using System.Threading.Channels;

namespace FruitVision.Api.Ai;

public sealed class LiveAiOptions
{
    public bool Enabled { get; set; }
    public string WorkerPath { get; set; } = "";
}
internal sealed class LiveAiSessionState
{
    public Guid Id = Guid.NewGuid(), UserId, AuthSessionId;
    public DateTimeOffset ExpiresAt, LastActivity;
    public long Sequence;
    public long? LastFrameTimestamp;
    public bool Busy, Ready, Stopped;
}
internal sealed record LiveAiLease(LiveAiSessionState Session, long Sequence, long ReceivedTimestamp);
internal sealed class LiveAiWork(LiveAiLease lease, byte[] jpeg, CancellationToken requestAborted)
{
    public LiveAiLease Lease { get; } = lease;
    public byte[] Jpeg { get; set; } = jpeg;
    public CancellationToken RequestAborted { get; } = requestAborted;
    public TaskCompletionSource<object> Completion { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
}

public sealed class LiveAiRuntime : IDisposable
{
    public const string ModelSha256 = "8a69c66a9444c18c98a7e3e58a44f4dddda9eb4583dd4448f430ff9e8db27c41";
    public const int MaximumFrameBytes = 1048576, MaximumEdge = 960, MinimumFrameIntervalMs = 150;
    private static readonly string[] StageLabels = ["Xanh / chưa chín", "Chín"];
    private readonly object gate = new();
    private readonly Dictionary<Guid, LiveAiSessionState> sessions = [];
    private readonly Channel<LiveAiWork> queue = Channel.CreateBounded<LiveAiWork>(new BoundedChannelOptions(1) { SingleReader = true, FullMode = BoundedChannelFullMode.Wait });
    private readonly SemaphoreSlim lifecycle = new(1, 1);
    private readonly CancellationTokenSource shutdown = new();
    private readonly ILiveAiEngine engine;
    private readonly IOptions<LiveAiOptions> options;
    private readonly IServiceScopeFactory scopes;
    private readonly TimeProvider clock;
    private readonly ILogger<LiveAiRuntime> logger;
    private readonly Task pump;
    private bool engineStarted;
    private int active, starting, pending, disposed;
    public LiveAiRuntime(ILiveAiEngine engine, IOptions<LiveAiOptions> options, IServiceScopeFactory scopes, TimeProvider clock, ILogger<LiveAiRuntime> logger)
    { this.engine = engine; this.options = options; this.scopes = scopes; this.clock = clock; this.logger = logger; pump = Task.Run(Pump); }
    // Includes draining inference/startup so Root's file-job admission guard cannot overlap CPU work after Stop.
    public bool HasActiveSessions { get { lock (gate) return sessions.Count > 0 || active > 0 || starting > 0; } }
    public int PendingFrameCount => Volatile.Read(ref pending);

    internal (Guid Id, bool Created) Reserve(Guid userId, Guid authSessionId, DateTimeOffset accessExpiresAt)
    {
        if (!options.Value.Enabled || !engine.IsReady) throw new LiveAiException(503, "LIVE_AI_UNAVAILABLE");
        lock (gate)
        {
            var previous = sessions.Values.SingleOrDefault(s => s.UserId == userId);
            if (previous is not null)
            {
                if (previous.AuthSessionId != authSessionId) throw new LiveAiException(409, "LIVE_USER_ALREADY_ACTIVE");
                previous.LastActivity = clock.GetUtcNow(); return (previous.Id, false);
            }
            if (sessions.Count >= 2) throw new LiveAiException(429, "LIVE_CAPACITY_BUSY");
            var maximum = clock.GetUtcNow().AddMinutes(10);
            var state = new LiveAiSessionState { UserId = userId, AuthSessionId = authSessionId, LastActivity = clock.GetUtcNow(),
                ExpiresAt = accessExpiresAt < maximum ? accessExpiresAt : maximum };
            sessions.Add(state.Id, state); return (state.Id, true);
        }
    }
    internal async Task PrepareAsync(Guid id, Guid userId, Guid authSessionId, CancellationToken ct)
    {
        await lifecycle.WaitAsync(ct);
        try
        {
            if (!engineStarted)
            {
                lock (gate) starting++;
                try
                {
                    using var startup = CancellationTokenSource.CreateLinkedTokenSource(ct, shutdown.Token); startup.CancelAfter(TimeSpan.FromSeconds(15));
                    await engine.StartAsync(startup.Token); engineStarted = true;
                }
                catch (Exception error)
                {
                    lock (gate) { foreach (var state in sessions.Values) state.Stopped = true; sessions.Clear(); }
                    await engine.StopAsync(CancellationToken.None); engineStarted = false;
                    logger.LogWarning("Live AI startup failed ({FailureType}).", error.GetType().Name);
                    throw new LiveAiException(503, "LIVE_AI_UNAVAILABLE");
                }
                finally { lock (gate) starting--; }
            }
            lock (gate) Owned(id, userId, authSessionId).Ready = true;
        }
        finally { lifecycle.Release(); }
    }
    internal object Describe(Guid id, Guid userId, Guid authSessionId)
    {
        lock (gate)
        {
            var state = Owned(id, userId, authSessionId);
            return new { id = state.Id, scope = "predicted-mango-only", modelSha256 = ModelSha256, state.ExpiresAt,
                idleTimeoutSeconds = 30, maxFrameBytes = MaximumFrameBytes, maxEdge = MaximumEdge,
                minFrameIntervalMs = MinimumFrameIntervalMs, nextSequence = state.Sequence + 1 };
        }
    }
    private LiveAiSessionState Owned(Guid id, Guid userId, Guid authSessionId)
    {
        if (!sessions.TryGetValue(id, out var state) || state.UserId != userId || state.AuthSessionId != authSessionId || state.Stopped)
            throw new LiveAiException(404, "LIVE_SESSION_NOT_FOUND");
        return state;
    }
    internal void RequireOwned(Guid id, Guid userId, Guid authSessionId) { lock (gate) Owned(id, userId, authSessionId); }
    internal LiveAiLease Claim(Guid id, Guid userId, Guid authSessionId, long sequence)
    {
        lock (gate)
        {
            var state = Owned(id, userId, authSessionId); var now = clock.GetTimestamp();
            if (!state.Ready) throw new LiveAiException(409, "LIVE_SESSION_STARTING");
            if (sequence <= state.Sequence) throw new LiveAiException(409, "LIVE_FRAME_STALE");
            if (state.Busy || (state.LastFrameTimestamp.HasValue && clock.GetElapsedTime(state.LastFrameTimestamp.Value, now).TotalMilliseconds < MinimumFrameIntervalMs))
                throw new LiveAiException(429, "LIVE_FRAME_BUSY");
            state.Busy = true; state.Sequence = sequence; state.LastFrameTimestamp = now; state.LastActivity = clock.GetUtcNow();
            return new(state, sequence, now);
        }
    }
    internal void Release(LiveAiLease lease) { lock (gate) lease.Session.Busy = false; }
    internal async Task<object> SubmitAsync(LiveAiLease lease, byte[] jpeg, CancellationToken aborted)
    {
        var work = new LiveAiWork(lease, jpeg, aborted); Interlocked.Increment(ref pending);
        if (!queue.Writer.TryWrite(work))
        { Interlocked.Decrement(ref pending); Release(lease); Array.Clear(jpeg); throw new LiveAiException(429, "LIVE_FRAME_BUSY"); }
        return await work.Completion.Task.WaitAsync(aborted);
    }
    internal async Task StopAsync(Guid id, Guid userId, Guid authSessionId, CancellationToken ct)
    {
        lock (gate)
        {
            if (sessions.TryGetValue(id, out var state))
            {
                if (state.UserId != userId || state.AuthSessionId != authSessionId) throw new LiveAiException(404, "LIVE_SESSION_NOT_FOUND");
                state.Stopped = true; sessions.Remove(id);
            }
        }
        await StopIfIdle(ct);
    }
    internal async Task PruneAsync(CancellationToken ct, bool checkAuthorization = false)
    {
        LiveAiSessionState[] snapshot;
        lock (gate)
        {
            var now = clock.GetUtcNow();
            foreach (var state in sessions.Values.Where(s => s.ExpiresAt <= now || now - s.LastActivity >= TimeSpan.FromSeconds(30)).ToArray())
            { state.Stopped = true; sessions.Remove(state.Id); }
            snapshot = sessions.Values.ToArray();
        }
        if (checkAuthorization)
            foreach (var state in snapshot)
                if (!await Authorized(state, ct))
                    lock (gate) { state.Stopped = true; sessions.Remove(state.Id); }
        await StopIfIdle(ct);
    }
    private bool Current(LiveAiSessionState state)
    { lock (gate) return !state.Stopped && sessions.TryGetValue(state.Id, out var current) && ReferenceEquals(current, state) && state.ExpiresAt > clock.GetUtcNow(); }
    private async Task<bool> Authorized(LiveAiSessionState state, CancellationToken ct)
    {
        using var scope = scopes.CreateScope(); var db = scope.ServiceProvider.GetRequiredService<AppDbContext>(); var now = clock.GetUtcNow();
        return await db.AuthSessions.AsNoTracking().AnyAsync(s => s.Id == state.AuthSessionId && s.UserId == state.UserId && s.RevokedAt == null && s.AccessExpiresAt > now &&
            s.SecurityStamp == s.User.SecurityStamp && s.User.IsActive && s.User.ApprovalStatus == ApprovalState.Approved &&
            (s.User.Role == AccountRole.Producer || s.User.Role == AccountRole.Trader), ct);
    }
    private async Task StopIfIdle(CancellationToken ct)
    {
        if (HasActiveSessions) return;
        await lifecycle.WaitAsync(ct);
        try { if (!HasActiveSessions && engineStarted) { await engine.StopAsync(ct); engineStarted = false; } }
        finally { lifecycle.Release(); }
    }
    private async Task Fault()
    {
        lock (gate) { foreach (var state in sessions.Values) state.Stopped = true; sessions.Clear(); }
        await lifecycle.WaitAsync();
        try { await engine.StopAsync(CancellationToken.None); engineStarted = false; }
        finally { lifecycle.Release(); }
    }
    private async Task Pump()
    {
        try
        {
            await foreach (var work in queue.Reader.ReadAllAsync(shutdown.Token))
            {
                Interlocked.Decrement(ref pending); object? response = null; Exception? failure = null; var running = false;
                try
                {
                    var lease = work.Lease; var state = lease.Session;
                    if (work.RequestAborted.IsCancellationRequested) throw new LiveAiException(409, "LIVE_FRAME_ABANDONED");
                    if (!Current(state)) throw new LiveAiException(404, "LIVE_SESSION_NOT_FOUND");
                    if (clock.GetElapsedTime(lease.ReceivedTimestamp).TotalMilliseconds > 1500) throw new LiveAiException(409, "LIVE_FRAME_STALE");
                    if (!await Authorized(state, shutdown.Token)) throw new LiveAiException(401, "LIVE_SESSION_UNAUTHORIZED");
                    lock (gate) { if (!Current(state)) throw new LiveAiException(404, "LIVE_SESSION_NOT_FOUND"); active++; running = true; }
                    using var frameTimeout = CancellationTokenSource.CreateLinkedTokenSource(shutdown.Token); frameTimeout.CancelAfter(TimeSpan.FromSeconds(5));
                    // Once sent, drain one complete response even if the HTTP client leaves, preserving the shared protocol.
                    var result = await engine.InferAsync(work.Jpeg, frameTimeout.Token); Validate(result);
                    if (!Current(state)) throw new LiveAiException(409, "LIVE_SESSION_STOPPED");
                    if (!await Authorized(state, shutdown.Token)) throw new LiveAiException(401, "LIVE_SESSION_UNAUTHORIZED");
                    var counts = new Dictionary<string, int> { [StageLabels[0]] = 0, [StageLabels[1]] = 0, ["Chưa xác định"] = 0 };
                    foreach (var item in result.Objects) counts[item.StageLabel]++;
                    response = new { schema = "fruitvision-live-v1", sessionId = state.Id, sequence = lease.Sequence, result.ImageWidth, result.ImageHeight,
                        scope = "predicted-mango-only", modelSha256 = ModelSha256, objects = result.Objects, visibleCount = result.Objects.Count, stageCounts = counts,
                        result.ProcessingMs, serverLatencyMs = Math.Round(clock.GetElapsedTime(lease.ReceivedTimestamp).TotalMilliseconds, 3),
                        summary = result.Objects.Count == 0 ? "Không phát hiện xoài đạt ngưỡng" : "Phát hiện xoài dự đoán đạt ngưỡng",
                        limitations = new[] { "Chỉ giữ xoài được mô hình dự đoán; có thể bỏ sót hoặc nhận nhầm. Không phát hiện không chứng minh không có xoài.",
                            "Hai nhãn giai đoạn nguồn không xác nhận độ chín, chất lượng bên trong hoặc an toàn thực phẩm.",
                            "Số thấy trong khung hiện tại không phải số quả duy nhất, khối lượng hay tồn kho; khung cũ/bận có thể bị bỏ.",
                            "Camera liên tục nhưng tốc độ AI phụ thuộc PC và mạng; không bảo đảm FPS. Bản trình diễn phi thương mại, tối đa64 đối tượng/khung." } };
                    lock (gate) state.LastActivity = clock.GetUtcNow();
                }
                catch (Exception error)
                {
                    failure = error is LiveAiException ? error : new LiveAiException(503, "LIVE_AI_UNAVAILABLE");
                    if (failure is LiveAiException { Status: 401 })
                        lock (gate) { work.Lease.Session.Stopped = true; sessions.Remove(work.Lease.Session.Id); }
                    if (failure is LiveAiException { Status: 503 })
                    { logger.LogWarning("Live AI frame failed ({FailureType}).", error.GetType().Name); await Fault(); }
                }
                finally
                {
                    Array.Clear(work.Jpeg); work.Jpeg = [];
                    Release(work.Lease); if (running) lock (gate) active--;
                    await StopIfIdle(CancellationToken.None);
                }
                if (failure is not null) work.Completion.TrySetException(failure); else work.Completion.TrySetResult(response!);
            }
        }
        catch (OperationCanceledException) when (shutdown.IsCancellationRequested) { }
    }
    private static void Validate(LiveAiFrameResult result)
    {
        if (result.ImageWidth is < 1 or > MaximumEdge || result.ImageHeight is < 1 or > MaximumEdge || result.Objects is null || result.Objects.Count > 64 ||
            !double.IsFinite(result.ProcessingMs) || result.ProcessingMs < 0) throw new LiveAiException(503, "LIVE_AI_INVALID_RESULT");
        foreach (var obj in result.Objects)
            if (obj.Box is null || obj.Box.Length != 4 || obj.Box.Any(v => !double.IsFinite(v) || v < 0 || v > 1) || obj.Box[0] >= obj.Box[2] || obj.Box[1] >= obj.Box[3] ||
                !double.IsFinite(obj.Score) || obj.Score < 0 || obj.Score > 1 || obj.FruitLabel != "Xoài (dự đoán)" || obj.StageCode is < -1 or > 1 ||
                obj.StageLabel != (obj.StageCode < 0 ? "Chưa xác định" : StageLabels[obj.StageCode])) throw new LiveAiException(503, "LIVE_AI_INVALID_RESULT");
    }
    public void Dispose()
    {
        if (Interlocked.Exchange(ref disposed, 1) != 0) return;
        shutdown.Cancel(); queue.Writer.TryComplete();
        lock (gate) { foreach (var state in sessions.Values) state.Stopped = true; sessions.Clear(); }
        try { engine.StopAsync(CancellationToken.None).WaitAsync(TimeSpan.FromSeconds(2)).GetAwaiter().GetResult(); } catch (Exception error) { logger.LogWarning("Live AI shutdown failed ({FailureType}).", error.GetType().Name); }
        try { pump.WaitAsync(TimeSpan.FromSeconds(2)).GetAwaiter().GetResult(); } catch (Exception error) { logger.LogWarning("Live AI dispatcher shutdown incomplete ({FailureType}).", error.GetType().Name); }
        while (queue.Reader.TryRead(out var work)) { Array.Clear(work.Jpeg); work.Completion.TrySetCanceled(); }
        shutdown.Dispose();
    }
}
public sealed class LiveAiMaintenance(LiveAiRuntime runtime, ILogger<LiveAiMaintenance> logger) : BackgroundService
{
    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        using var timer = new PeriodicTimer(TimeSpan.FromSeconds(5));
        try { while (await timer.WaitForNextTickAsync(stoppingToken)) { try { await runtime.PruneAsync(stoppingToken, checkAuthorization: true); } catch (Exception error) when (!stoppingToken.IsCancellationRequested) { logger.LogWarning("Live AI cleanup failed ({FailureType}).", error.GetType().Name); } } }
        catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested) { }
    }
}
public static class LiveAiRegistration
{
    public static IServiceCollection AddLiveAi(this IServiceCollection services, IConfiguration configuration)
    {
        services.Configure<LiveAiOptions>(configuration.GetSection("AiLive"));
        services.TryAddSingleton<TimeProvider>(TimeProvider.System);
        services.AddSingleton<ILiveAiEngine, LiveAiEngine>(); services.AddSingleton<LiveAiRuntime>();
        services.AddHostedService<LiveAiMaintenance>();
        return services;
    }
}
