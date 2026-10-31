using System.Globalization;
using FruitVision.Api.Auth;
using FruitVision.Api.Data;
using FruitVision.Api.Infrastructure;
using Microsoft.AspNetCore.Http.Features;
using Microsoft.EntityFrameworkCore;

namespace FruitVision.Api.Ai;

public sealed record LiveAiFrameRateMetadata;
public static class LiveAiEndpoints
{
    public static void MapLiveAi(this WebApplication app)
    {
        var group = app.MapGroup("/api/v1/ai/live").RequireAuthorization("Seller").WithTags("Camera trực tiếp qua PC");
        group.MapPost("/sessions", Start).AddEndpointFilter<InputFilter>();
        group.MapPost("/sessions/{id:guid}/frames", Frame).WithMetadata(new LiveAiFrameRateMetadata());
        group.MapDelete("/sessions/{id:guid}", async (Guid id, HttpContext http, LiveAiRuntime runtime, CancellationToken ct) =>
        {
            try { await runtime.StopAsync(id, http.User.UserId(), http.User.SessionId(), ct); return Results.NoContent(); }
            catch (LiveAiException error) { return Failure(http, error); }
        });
    }
    private static async Task<IResult> Start(LiveAiStartRequest request, HttpContext http, AppDbContext db,
        LiveAiRuntime runtime, TimeProvider clock, CancellationToken ct)
    {
        var userId = http.User.UserId(); var authSessionId = http.User.SessionId(); Guid? reservedId = null; var created = false;
        try
        {
            await runtime.PruneAsync(ct, checkAuthorization: true);
            await using (var transaction = await db.Database.BeginTransactionAsync(ct))
            {
                // Root's file-job upload guard uses this same admission lock plus HasActiveSessions.
                await db.Database.ExecuteSqlRawAsync("SELECT pg_advisory_xact_lock(823012841)", ct);
                var auth = await db.AuthSessions.AsNoTracking().Include(s => s.User).SingleOrDefaultAsync(s => s.Id == authSessionId && s.UserId == userId, ct);
                if (auth is null || !Eligible(auth, clock.GetUtcNow())) return Failure(http, new LiveAiException(401, "LIVE_SESSION_UNAUTHORIZED"));
                if (await db.Set<AiJob>().AnyAsync(j => j.Status == AiJobStatus.Queued || j.Status == AiJobStatus.Running, ct))
                    return Failure(http, new LiveAiException(409, "LIVE_FILE_JOB_ACTIVE"));
                var reservation = runtime.Reserve(userId, authSessionId, auth.AccessExpiresAt); reservedId = reservation.Id; created = reservation.Created;
                await transaction.CommitAsync(ct);
            }
            await runtime.PrepareAsync(reservedId.Value, userId, authSessionId, ct);
            var fresh = await db.AuthSessions.AsNoTracking().Include(s => s.User).SingleOrDefaultAsync(s => s.Id == authSessionId && s.UserId == userId, ct);
            if (fresh is null || !Eligible(fresh, clock.GetUtcNow()))
            { await runtime.StopAsync(reservedId.Value, userId, authSessionId, CancellationToken.None); return Failure(http, new LiveAiException(401, "LIVE_SESSION_UNAUTHORIZED")); }
            var value = runtime.Describe(reservedId.Value, userId, authSessionId);
            return created ? Results.Json(value, statusCode: 201) : Results.Ok(value);
        }
        catch (LiveAiException error)
        {
            if (created && reservedId.HasValue) await runtime.StopAsync(reservedId.Value, userId, authSessionId, CancellationToken.None);
            return Failure(http, error);
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested)
        {
            if (created && reservedId.HasValue) await runtime.StopAsync(reservedId.Value, userId, authSessionId, CancellationToken.None);
            throw;
        }
    }
    private static bool Eligible(AuthSession session, DateTimeOffset now) => session.RevokedAt is null && session.AccessExpiresAt > now &&
        session.SecurityStamp == session.User.SecurityStamp && session.User.IsActive && session.User.ApprovalStatus == ApprovalState.Approved &&
        session.User.Role is AccountRole.Producer or AccountRole.Trader;

    private static async Task<IResult> Frame(Guid id, HttpContext http, LiveAiRuntime runtime, CancellationToken ct)
    {
        LiveAiLease? lease = null; byte[]? jpeg = null; var submitted = false;
        try
        {
            await runtime.PruneAsync(ct);
            runtime.RequireOwned(id, http.User.UserId(), http.User.SessionId());
            if (http.Request.ContentType?.Split(';')[0].Trim().ToLowerInvariant() != "image/jpeg") throw new LiveAiException(415, "LIVE_JPEG_REQUIRED");
            if (http.Request.ContentLength > LiveAiRuntime.MaximumFrameBytes) throw new LiveAiException(413, "LIVE_FRAME_TOO_LARGE");
            if (!long.TryParse(http.Request.Headers["X-Frame-Sequence"].ToString(), NumberStyles.None, CultureInfo.InvariantCulture, out var sequence) || sequence is <= 0 or > int.MaxValue)
                throw new LiveAiException(400, "LIVE_SEQUENCE_INVALID");
            lease = runtime.Claim(id, http.User.UserId(), http.User.SessionId(), sequence);
            if (http.Features.Get<IHttpMaxRequestBodySizeFeature>() is { IsReadOnly: false } maximum) maximum.MaxRequestBodySize = LiveAiRuntime.MaximumFrameBytes;
            using var upload = CancellationTokenSource.CreateLinkedTokenSource(ct); upload.CancelAfter(TimeSpan.FromSeconds(3));
            try { jpeg = await ReadFrame(http.Request.Body, upload.Token); }
            catch (OperationCanceledException) when (!ct.IsCancellationRequested) { throw new LiveAiException(408, "LIVE_UPLOAD_TIMEOUT"); }
            submitted = true;
            return Results.Ok(await runtime.SubmitAsync(lease, jpeg, ct));
        }
        catch (LiveAiException error) { return Failure(http, error); }
        catch (BadHttpRequestException error) when (error.StatusCode == 413) { return Failure(http, new LiveAiException(413, "LIVE_FRAME_TOO_LARGE")); }
        finally
        {
            if (!submitted) { if (lease is not null) runtime.Release(lease); if (jpeg is not null) Array.Clear(jpeg); }
        }
    }
    private static async Task<byte[]> ReadFrame(Stream source, CancellationToken ct)
    {
        using var output = new MemoryStream(); var buffer = new byte[65536];
        while (true)
        {
            var size = await source.ReadAsync(buffer.AsMemory(), ct); if (size == 0) break;
            if (output.Length + size > LiveAiRuntime.MaximumFrameBytes) throw new LiveAiException(413, "LIVE_FRAME_TOO_LARGE");
            await output.WriteAsync(buffer.AsMemory(0, size), ct);
        }
        var value = output.ToArray();
        if (value.Length < 4 || !value.AsSpan(0, 3).SequenceEqual(new byte[] { 255, 216, 255 }))
        { Array.Clear(value); throw new LiveAiException(422, "LIVE_FRAME_INVALID"); }
        return value;
    }
    private static IResult Failure(HttpContext http, LiveAiException error)
    {
        if (error.Status == 429) http.Response.Headers.RetryAfter = "1";
        return Results.Problem(statusCode: error.Status, title: error.Status switch
        {
            400 => "Số thứ tự khung không hợp lệ.", 401 => "Phiên đăng nhập không còn hợp lệ.", 404 => "Không tìm thấy phiên camera hoặc bạn không có quyền truy cập.",
            408 => "Tải khung camera quá chậm; hãy chụp khung mới.", 409 => "Khung đã cũ, phiên đã đổi hoặc đang có tác vụ tệp; hãy đọc lại trạng thái và dùng khung mới.",
            413 => "Khung camera vượt 1 MiB.", 415 => "Camera trực tiếp chỉ nhận JPEG.", 422 => "JPEG không hợp lệ hoặc kích thước vượt 960 pixel.",
            429 => "Bộ xử lý đang bận; hãy bỏ khung cũ và gửi khung mới sau.", _ => "Bộ xử lý camera AI trên PC chưa sẵn sàng."
        }, extensions: new Dictionary<string, object?> { ["code"] = error.Code });
    }
}

public sealed record LiveAiStartRequest;
