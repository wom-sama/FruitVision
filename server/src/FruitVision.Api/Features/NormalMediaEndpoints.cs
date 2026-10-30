using FruitVision.Api.Auth;
using FruitVision.Api.Contracts;
using FruitVision.Api.Data;
using FruitVision.Api.Infrastructure;
using Microsoft.AspNetCore.Http.Features;
using Microsoft.EntityFrameworkCore;

namespace FruitVision.Api.Features;

public static class NormalMediaEndpoints
{
    public static void MapNormalMedia(this WebApplication app)
    {
        app.MapPost("/api/v1/articles/images", UploadArticleImage).RequireAuthorization("Approved")
            .RequireAuthorization(p => p.RequireRole("Consumer", "Producer", "Trader"));
        app.MapPost("/api/v1/conversations/{id:guid}/images", SendImage).RequireAuthorization("Approved");
        app.MapGet("/api/v1/articles/{id:guid}/image", async (Guid id, HttpContext http, AppDbContext db, NormalMediaStorage storage, CancellationToken ct) =>
        {
            var article = await db.Set<CommunityArticle>().AsNoTracking().Include(a => a.Author).Include(a => a.Branch).Include(a => a.Image).SingleOrDefaultAsync(a => a.Id == id, ct);
            if (article?.Image is null) return Results.NotFound();
            var privateView = http.User.Identity?.IsAuthenticated == true && http.User.HasClaim("approval", "Approved") &&
                (http.User.UserId() == article.AuthorId || http.User.IsInRole("Admin"));
            if (!privateView && !PublishingEndpoints.IsArticlePublic(article)) return Results.NotFound();
            return Download(article.Image, http, storage);
        });
        app.MapGet("/api/v1/conversations/{id:guid}/images/{imageId:guid}", async (Guid id, Guid imageId, HttpContext http, AppDbContext db, NormalMediaStorage storage, CancellationToken ct) =>
        {
            var uid = http.User.UserId();
            if (!await db.Participants.AnyAsync(p => p.ConversationId == id && p.UserId == uid, ct)) return Results.NotFound();
            var image = await db.Set<NormalImage>().AsNoTracking().SingleOrDefaultAsync(i => i.Id == imageId && i.Purpose == "Chat" && i.ConversationId == id, ct);
            return image is null ? Results.NotFound() : Download(image, http, storage);
        }).RequireAuthorization("Approved");
    }
    public static object ImageView(NormalImage image, string? downloadPath = null) => new
    { image.Id, image.ContentType, image.Width, image.Height, image.SizeBytes, downloadPath };
    public static object MessageView(Message message, MessageSenderView sender, NormalImage? image) => new
    {
        message.Id, message.ConversationId, message.SenderId, message.ClientMessageId, message.Text, message.CreatedAt, sender,
        image = image is null ? null : ImageView(image, $"/api/v1/conversations/{message.ConversationId}/images/{image.Id}")
    };
    public static async Task<NormalImage?> ClaimArticleImage(AppDbContext db, Guid ownerId, Guid? imageId, Guid? currentImageId, CancellationToken ct)
    {
        if (!imageId.HasValue) return null;
        var image = await db.Set<NormalImage>().FromSqlInterpolated($"SELECT * FROM \"NormalImages\" WHERE \"Id\"={imageId.Value} FOR UPDATE").SingleOrDefaultAsync(ct);
        if (image is null || image.OwnerId != ownerId || image.Purpose != "Article" || (image.ConsumedAt.HasValue && image.Id != currentImageId))
            throw new NormalImageException(400, "IMAGE_NOT_OWNED_OR_ALREADY_USED");
        image.ConsumedAt ??= DateTimeOffset.UtcNow;
        return image;
    }
    private static IResult Download(NormalImage image, HttpContext http, NormalMediaStorage storage)
    {
        try
        {
            var file = storage.Open(image); if (file is null) return Results.NotFound();
            http.Response.Headers.CacheControl = "private, no-store";
            http.Response.Headers["X-Content-Type-Options"] = "nosniff";
            return Results.File(file, "image/jpeg");
        }
        catch (NormalImageException e) { return Failure(e); }
    }
    private static void LimitBody(HttpContext http)
    {
        if (http.Features.Get<IHttpMaxRequestBodySizeFeature>() is { IsReadOnly: false } feature) feature.MaxRequestBodySize = NormalMediaOptions.MaximumBytes;
    }
    private static IResult Failure(NormalImageException e) => Results.Json(new { code = e.Code, message = e.StatusCode switch
    {
        400 => "Ảnh không thuộc tài khoản hoặc đã được dùng cho bài khác.",
        413 => "Ảnh vượt giới hạn 5 MiB.", 415 => "Chỉ nhận ảnh JPEG hoặc PNG.",
        422 => "Ảnh không hợp lệ, quá lớn hoặc có nhiều khung.", 429 => "Bộ xử lý ảnh đang bận; hãy thử lại sau.",
        _ => "Bộ xử lý hoặc kho ảnh chưa sẵn sàng."
    } }, statusCode: e.StatusCode);
    private static NormalImage Record(Guid id, Guid uid, string purpose, Guid? conversationId, string rawHash, ProcessedNormalImage result) => new()
    {
        Id = id, OwnerId = uid, Purpose = purpose, ConversationId = conversationId,
        RawSha256 = rawHash, Sha256 = result.Sha256, Width = result.Width, Height = result.Height, SizeBytes = result.SizeBytes
    };
    private static async Task<IResult> UploadArticleImage(HttpContext http, AppDbContext db, NormalMediaStorage storage, INormalImageProcessor processor, IConfiguration configuration, CancellationToken ct)
    {
        LimitBody(http); var id = Guid.NewGuid(); string? raw = null, canonical = null, final = null; var committed = false;
        try
        {
            raw = storage.Staging(id, ".upload"); canonical = storage.Staging(id, ".jpg");
            var hash = await storage.ReceiveAsync(http.Request, raw, ct);
            var result = await processor.ProcessAsync(raw, canonical, ct);
            var uid = http.User.UserId(); await using var transaction = await db.Database.BeginTransactionAsync(ct);
            var owner = await db.Users.FromSqlInterpolated($"SELECT * FROM \"AspNetUsers\" WHERE \"Id\"={uid} FOR SHARE").SingleAsync(ct);
            if (!owner.IsActive || owner.ApprovalStatus != ApprovalState.Approved || owner.Role == AccountRole.Admin) return Results.Forbid();
            var image = Record(id, uid, "Article", null, hash, result);
            final = storage.ImagePath(id);
            await MediaStorageQuota.EnsureAsync(db, uid, result.SizeBytes, Path.GetDirectoryName(final)!, configuration, ct);
            File.Move(canonical, final);
            db.Add(image); await db.SaveChangesAsync(ct); await transaction.CommitAsync(ct); committed = true;
            // An unattached upload has no download URL; only a readable article exposes its image.
            return Results.Json(new { image.Id, image.ContentType, image.Width, image.Height, image.SizeBytes }, statusCode: 201);
        }
        catch (NormalImageException e) { return Failure(e); }
        catch (MediaQuotaException e) { return Results.Problem(statusCode: e.Status, title: e.Message); }
        catch (IOException) { return Failure(new NormalImageException(503, "IMAGE_STORAGE_UNAVAILABLE")); }
        finally { storage.Remove(raw); storage.Remove(canonical); if (!committed) storage.Remove(final); }
    }
    private static async Task<IResult> SendImage(Guid id, string? clientMessageId, HttpContext http, AppDbContext db, NormalMediaStorage storage, INormalImageProcessor processor, IConfiguration configuration, CancellationToken ct)
    {
        if (clientMessageId is null || clientMessageId.Length is < 8 or > 64 || !Input.Safe(clientMessageId) || clientMessageId != Input.Text(clientMessageId))
            return Input.Invalid("clientMessageId cần 8–64 ký tự hợp lệ.");
        var uid = http.User.UserId();
        if (!await db.Participants.AnyAsync(p => p.ConversationId == id && p.UserId == uid, ct)) return Results.NotFound();
        LimitBody(http); var imageId = Guid.NewGuid(); string? raw = null, canonical = null, final = null; var committed = false;
        try
        {
            raw = storage.Staging(imageId, ".upload"); canonical = storage.Staging(imageId, ".jpg");
            var hash = await storage.ReceiveAsync(http.Request, raw, ct);
            await using var transaction = await db.Database.BeginTransactionAsync(ct);
            var conversation = await db.Conversations.FromSqlInterpolated($"SELECT * FROM \"Conversations\" WHERE \"Id\"={id} FOR UPDATE").SingleOrDefaultAsync(ct);
            if (conversation is null || conversation.Kind is not ("Direct" or "Group") || !await db.Participants.AnyAsync(p => p.ConversationId == id && p.UserId == uid, ct)) return Results.NotFound();
            var user = await db.Users.FromSqlInterpolated($"SELECT * FROM \"AspNetUsers\" WHERE \"Id\"={uid} FOR SHARE").SingleAsync(ct);
            if (!user.IsActive || user.ApprovalStatus != ApprovalState.Approved) return Results.Forbid();
            var sender = new MessageSenderView(uid, user.DisplayName, user.Role.ToString());
            var old = await db.Messages.AsNoTracking().SingleOrDefaultAsync(m => m.ConversationId == id && m.SenderId == uid && m.ClientMessageId == clientMessageId, ct);
            if (old is not null)
            {
                var oldImage = old.NormalImageId.HasValue ? await db.Set<NormalImage>().AsNoTracking().SingleOrDefaultAsync(i => i.Id == old.NormalImageId.Value, ct) : null;
                return oldImage?.RawSha256 == hash ? Results.Ok(MessageView(old, sender, oldImage)) : Results.Conflict(new { message = "Khóa tin nhắn đã được dùng với nội dung khác." });
            }
            if (conversation.Kind == "Group" && !conversation.IsOpen) return Results.Conflict(new { message = "Nhóm đã đóng, không nhận ảnh mới." });
            var result = await processor.ProcessAsync(raw, canonical, ct);
            var image = Record(imageId, uid, "Chat", id, hash, result); image.ConsumedAt = DateTimeOffset.UtcNow;
            var message = new Message { ConversationId = id, SenderId = uid, ClientMessageId = clientMessageId, Text = "[Hình ảnh]", NormalImageId = imageId };
            final = storage.ImagePath(imageId);
            await MediaStorageQuota.EnsureAsync(db, uid, result.SizeBytes, Path.GetDirectoryName(final)!, configuration, ct);
            File.Move(canonical, final);
            db.Add(image); db.Messages.Add(message); db.OutboxEvents.Add(new OutboxEvent { ConversationId = id, MessageId = message.Id });
            await db.SaveChangesAsync(ct); await transaction.CommitAsync(ct); committed = true;
            return Results.Created($"/api/v1/conversations/{id}/messages", MessageView(message, sender, image));
        }
        catch (NormalImageException e) { return Failure(e); }
        catch (MediaQuotaException e) { return Results.Problem(statusCode: e.Status, title: e.Message); }
        catch (IOException) { return Failure(new NormalImageException(503, "IMAGE_STORAGE_UNAVAILABLE")); }
        finally { storage.Remove(raw); storage.Remove(canonical); if (!committed) storage.Remove(final); }
    }
}
