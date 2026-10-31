using FruitVision.Api.Auth;
using FruitVision.Api.Data;
using Microsoft.AspNetCore.Http.Features;
using Microsoft.EntityFrameworkCore;

namespace FruitVision.Api.Ai;

public static class AiEndpoints
{
    public static void MapFruitVisionAi(this WebApplication app)
    {
        var group = app.MapGroup("/api/v1/ai").RequireAuthorization("Seller").WithTags("AI ảnh/video và đếm quả");
        group.MapGet("/capabilities", (AiRuntimeStatus runtime) => Results.Ok(new
        {
            aiReady = runtime.IsReady, message = runtime.Message, modelName = runtime.ModelName,
            maxImageBytes = AiOptions.MaxImageBytes, maxVideoBytes = AiOptions.MaxVideoBytes
        }));
        group.MapPost("/jobs", UploadAsync).WithSummary("Tải tệp nhị phân để tạo tác vụ AI riêng tư");
        group.MapGet("/jobs", async (HttpContext http, AppDbContext db, CancellationToken cancellationToken) =>
        {
            var userId = http.User.UserId();
            var jobs = await db.Set<AiJob>().AsNoTracking().Where(job => job.UserId == userId)
                .OrderByDescending(job => job.CreatedAt).ThenByDescending(job => job.Id).Take(20).ToListAsync(cancellationToken);
            return Results.Ok(new { items = jobs.Select(AiJobView.From) });
        });
        group.MapGet("/jobs/{id:guid}", async (Guid id, HttpContext http, AppDbContext db, CancellationToken cancellationToken) =>
        {
            var job = await OwnedAsync(db, id, http.User.UserId(), cancellationToken);
            return job is null ? Results.NotFound() : Results.Ok(AiJobView.From(job));
        });
        group.MapGet("/jobs/{id:guid}/preview", async (Guid id, HttpContext http, AppDbContext db,
            AiStorage storage, CancellationToken cancellationToken) =>
        {
            var job = await OwnedAsync(db, id, http.User.UserId(), cancellationToken);
            if (job is null || !job.PreviewAvailable || job.Status != AiJobStatus.Succeeded) return Results.NotFound();
            var preview = storage.OpenPreview(id);
            return preview is null ? Results.NotFound() : Results.File(preview, "image/jpeg", enableRangeProcessing: false);
        });
        group.MapPost("/jobs/{id:guid}/cancel", async (Guid id, HttpContext http, AppDbContext db,
            AiJobControl control, AiJobEvents events, AiStorage storage, CancellationToken cancellationToken) =>
        {
            await using var transaction = await db.Database.BeginTransactionAsync(cancellationToken);
            var userId = http.User.UserId();
            var job = await db.Set<AiJob>().FromSqlInterpolated(
                $"SELECT * FROM \"AiJobs\" WHERE \"Id\"={id} AND \"UserId\"={userId} FOR UPDATE").SingleOrDefaultAsync(cancellationToken);
            if (job is null) return Results.NotFound();
            if (job.Status is AiJobStatus.Queued or AiJobStatus.Running)
            {
                var wasQueued = job.Status == AiJobStatus.Queued;
                job.Status = AiJobStatus.Cancelled;
                job.Revision++;
                job.CompletedAt = DateTimeOffset.UtcNow;
                db.InteractionHistories.Add(AiJobEvents.History(job));
                await db.SaveChangesAsync(cancellationToken);
                await transaction.CommitAsync(cancellationToken);
                control.Cancel(id);
                if (wasQueued) storage.RemoveInput(job);
                await events.PublishAsync(job, cancellationToken);
            }
            return Results.Ok(AiJobView.From(job));
        });
    }

    private static Task<AiJob?> OwnedAsync(AppDbContext db, Guid id, Guid userId, CancellationToken cancellationToken) =>
        db.Set<AiJob>().AsNoTracking().SingleOrDefaultAsync(job => job.Id == id && job.UserId == userId, cancellationToken);

    private static IResult Invalid(int status, string message) => Results.Problem(statusCode: status, title: message);
    private static IResult Busy(HttpContext http)
    {
        http.Response.Headers.RetryAfter = "5";
        return Invalid(429, "Hàng đợi AI đang bận. Hãy chờ tác vụ hiện tại hoàn tất hoặc thử lại sau.");
    }

    private static async Task<IResult> UploadAsync(HttpContext http, AppDbContext db, AiStorage storage,
        AiJobControl control, AiJobEvents events, AiRuntimeStatus runtime, LiveAiRuntime live)
    {
        var mediaType = http.Request.Query["mediaType"].ToString();
        if (mediaType is not ("image" or "video") || http.Request.Query.Count != 1)
            return Invalid(400, "mediaType phải là image hoặc video; không nhận URL hay đường dẫn tệp.");
        var contentType = http.Request.ContentType?.Split(';')[0].Trim().ToLowerInvariant();
        var extension = (mediaType, contentType) switch
        {
            ("image", "image/jpeg") => ".jpg", ("image", "image/png") => ".png", ("video", "video/mp4") => ".mp4", _ => null
        };
        if (extension is null) return Invalid(415, "Chỉ nhận ảnh JPEG, PNG hoặc video MP4 đúng Content-Type.");
        var key = http.Request.Headers["X-Client-Request-Id"].ToString();
        if (key.Length is < 8 or > 64 || key.Any(character => !char.IsAsciiLetterOrDigit(character) && character is not ('_' or '-')))
            return Invalid(400, "X-Client-Request-Id cần 8–64 ký tự chữ, số, gạch dưới hoặc gạch nối.");
        if (!runtime.IsReady) return Invalid(503, "Bộ xử lý AI chưa sẵn sàng.");
        var limit = mediaType == "image" ? AiOptions.MaxImageBytes : AiOptions.MaxVideoBytes;
        if (http.Request.ContentLength > limit) return Invalid(413, "Tệp vượt giới hạn dung lượng.");
        var bodyLimit = http.Features.Get<IHttpMaxRequestBodySizeFeature>();
        if (bodyLimit is { IsReadOnly: false }) bodyLimit.MaxRequestBodySize = limit;
        using var uploadTimeout = CancellationTokenSource.CreateLinkedTokenSource(http.RequestAborted);
        uploadTimeout.CancelAfter(TimeSpan.FromSeconds(90));
        var cancellationToken = uploadTimeout.Token;
        if (!await control.Admission.WaitAsync(0, cancellationToken)) return Busy(http);
        AiJob? job = null;
        var saved = false;
        try
        {
            await using var transaction = await db.Database.BeginTransactionAsync(cancellationToken);
            // Serializes admission across requests/hosts without exposing an incomplete upload to the worker.
            await db.Database.ExecuteSqlRawAsync("SELECT pg_advisory_xact_lock(823012841)", cancellationToken);
            var userId = http.User.UserId();
            if (!await db.Users.AnyAsync(user => user.Id == userId && user.IsActive &&
                user.ApprovalStatus == ApprovalState.Approved, cancellationToken)) return Results.Forbid();
            var prior = await db.Set<AiJob>().AsNoTracking().SingleOrDefaultAsync(
                item => item.UserId == userId && item.ClientRequestId == key, cancellationToken);
            if (prior is not null)
            {
                if (prior.MediaType != mediaType || prior.ContentType != contentType)
                    return Invalid(409, "Mã yêu cầu đã được dùng cho một loại tệp khác.");
                var digest = await storage.HashUploadAsync(contentType!, http.Request.Body, limit, cancellationToken);
                if (digest.Bytes != prior.InputBytes || !string.Equals(digest.Sha256, prior.InputSha256, StringComparison.Ordinal))
                    return Invalid(409, "Mã yêu cầu đã được dùng cho nội dung tệp khác. Hãy tạo mã yêu cầu mới.");
                return Results.Ok(AiJobView.From(prior));
            }
            // Same advisory lock as live-session admission: do not load a second model worker.
            if (live.HasActiveSessions) return Busy(http);
            var active = db.Set<AiJob>().Where(item => item.Status == AiJobStatus.Queued || item.Status == AiJobStatus.Running);
            if (await active.AnyAsync(item => item.UserId == userId, cancellationToken) ||
                await active.CountAsync(cancellationToken) >= 4) return Busy(http);
            job = new AiJob { UserId = userId, ClientRequestId = key, MediaType = mediaType,
                ContentType = contentType!, InputExtension = extension };
            await storage.SaveUploadAsync(job, http.Request.Body, limit, cancellationToken);
            db.Set<AiJob>().Add(job);
            await db.SaveChangesAsync(cancellationToken);
            await transaction.CommitAsync(cancellationToken);
            saved = true;
            await events.PublishAsync(job, http.RequestAborted);
            return Results.Accepted($"/api/v1/ai/jobs/{job.Id}", AiJobView.From(job));
        }
        catch (AiUploadException exception) { return Invalid(exception.Status, exception.Message); }
        catch (OperationCanceledException) when (!http.RequestAborted.IsCancellationRequested)
        { return Invalid(408, "Tải tệp quá thời gian cho phép."); }
        finally
        {
            control.Admission.Release();
            if (job is not null && !saved)
            {
                try { storage.RemoveIncomplete(job.Id); }
                catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or AiUploadException)
                { http.RequestServices.GetRequiredService<ILoggerFactory>().CreateLogger("AiUpload").LogWarning("Incomplete AI upload {JobId} could not be removed.", job.Id); }
            }
        }
    }
}
