using FruitVision.Api.Data;
using FruitVision.Api.Realtime;
using Microsoft.AspNetCore.SignalR;
using Microsoft.EntityFrameworkCore;

namespace FruitVision.Api.Ai;

public sealed class AiJobControl
{
    internal SemaphoreSlim Admission { get; } = new(1, 1);
    private readonly object gate = new();
    private Guid currentId;
    private CancellationTokenSource? current;
    public void Track(Guid id, CancellationTokenSource cancellation) { lock (gate) { currentId = id; current = cancellation; } }
    public void Untrack(Guid id) { lock (gate) { if (currentId == id) current = null; } }
    public void Cancel(Guid id) { lock (gate) { if (currentId == id) current?.Cancel(); } }
}

public sealed class AiJobEvents(IServiceScopeFactory scopes, IHubContext<FruitHub> hub, ILogger<AiJobEvents> logger)
{
    public async Task PublishAsync(AiJob job, CancellationToken cancellationToken = default)
    {
        try
        {
            await hub.Clients.Group($"user:{job.UserId}").SendAsync("AiJobChanged", new
            { id = job.Id, status = job.Status.ToString(), progress = job.Progress, framesProcessed = job.FramesProcessed, revision = job.Revision }, cancellationToken);
        }
        catch (Exception exception) when (exception is not OperationCanceledException)
        { logger.LogWarning("AI job {JobId} notification was not delivered.", job.Id); }
    }

    public static InteractionHistory History(AiJob job) => new()
    {
        UserId = job.UserId,
        Kind = "AiJob" + job.Status,
        Title = job.Status == AiJobStatus.Succeeded ? "Hoàn tất phân tích AI" :
            job.Status == AiJobStatus.Cancelled ? "Đã hủy phân tích AI" : "Phân tích AI không hoàn tất",
        Body = $"Tác vụ {job.Id}: {job.Status}. Kết quả chỉ mô tả ảnh hoặc video mẫu, không tự tạo khối lượng hay tồn kho.",
        IsDemo = false
    };

    public async Task FinishAsync(Guid id, AiJobStatus status, string? error = null,
        string? result = null, bool preview = false, CancellationToken cancellationToken = default)
    {
        using var scope = scopes.CreateScope();
        var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
        await using var transaction = await db.Database.BeginTransactionAsync(cancellationToken);
        var job = await db.Set<AiJob>().FromSqlInterpolated($"SELECT * FROM \"AiJobs\" WHERE \"Id\"={id} FOR UPDATE")
            .SingleOrDefaultAsync(cancellationToken);
        if (job is null || job.Status is not (AiJobStatus.Queued or AiJobStatus.Running)) return;
        if (status == AiJobStatus.Succeeded)
        {
            // Serialize the completion decision with account review/lock updates.
            var userId = job.UserId;
            var owner = await db.Users.FromSqlInterpolated($"SELECT * FROM \"AspNetUsers\" WHERE \"Id\"={userId} FOR SHARE")
                .SingleOrDefaultAsync(cancellationToken);
            if (owner is null || !owner.IsActive || owner.ApprovalStatus != ApprovalState.Approved)
            { status = AiJobStatus.Cancelled; result = null; preview = false; }
        }
        job.Status = status;
        job.Revision++;
        job.Error = error;
        job.CompletedAt = DateTimeOffset.UtcNow;
        job.ResultJson = result;
        job.PreviewAvailable = preview;
        if (status == AiJobStatus.Succeeded) job.Progress = 100;
        db.InteractionHistories.Add(History(job));
        await db.SaveChangesAsync(cancellationToken);
        await transaction.CommitAsync(cancellationToken);
        await PublishAsync(job, cancellationToken);
    }
}
