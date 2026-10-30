using System.Security.Cryptography;
using System.Text;
using FruitVision.Api.Auth;
using FruitVision.Api.Contracts;
using FruitVision.Api.Data;
using FruitVision.Api.Infrastructure;
using FruitVision.Api.Realtime;
using Microsoft.AspNetCore.SignalR;
using Microsoft.EntityFrameworkCore;

namespace FruitVision.Api.Features;

/// <summary>Authorizes and stores opaque envelopes. Private keys, signatures inside sealed packets,
/// plaintext and image keys are never accepted as separate server fields or decrypted here.</summary>
public static class SecretMessagingEndpoints
{
    public static IServiceCollection AddSecretMessaging(this IServiceCollection services, IConfiguration configuration)
    {
        services.Configure<SecretMessagesOptions>(configuration.GetSection("SecretMessages"));
        services.AddSingleton<SecretAttachmentStorage>();
        return services;
    }
    public static void MapSecretMessaging(this WebApplication app)
    {
        var routes = app.MapGroup("/api/v1/secret").RequireAuthorization("Seller").AddEndpointFilter<InputFilter>().WithTags("Hội thoại bí mật — dữ liệu mã hóa");
        routes.MapGet("/devices", Devices);
        routes.MapPost("/devices", RegisterDevice);
        routes.MapDelete("/devices/{deviceId:guid}", RevokeDevice);
        routes.MapPost("/conversations", CreateConversation);
        routes.MapGet("/conversations", Conversations);
        routes.MapGet("/conversations/{id:guid}", Detail);
        routes.MapGet("/conversations/{id:guid}/bundles", Bundles);
        routes.MapPost("/conversations/{id:guid}/messages", Send);
        routes.MapGet("/conversations/{id:guid}/messages", Messages);
        routes.MapPost("/conversations/{id:guid}/attachments", Upload);
        routes.MapGet("/conversations/{id:guid}/attachments/{attachmentId:guid}", Download);
    }

    private sealed record Pair(Guid DirectId, Guid First, Guid Second);
    private sealed record Context(SecretConversation Thread, Pair Members);
    private static bool Seller(AppUser? user) => user is { IsActive: true, ApprovalStatus: ApprovalState.Approved, Role: AccountRole.Producer or AccountRole.Trader } && !(user.LockoutEnd > DateTimeOffset.UtcNow);
    private static SecretDeviceView View(SecretDevice d) => new(d.DeviceId, d.UserId, d.Version, d.Label, d.EncryptionPublicKey, d.SigningPublicKey, d.CreatedAt, d.RevokedAt);
    private static SecretConversationView View(SecretConversation c) => new(c.Id, c.DirectConversationId, c.FirstUserId, c.SecondUserId, c.CreatedAt, c.LastActivityAt, c.NextSequence);
    private static Task<AppUser?> UserLock(AppDbContext db, Guid id, CancellationToken ct) => db.Users.FromSqlInterpolated($"SELECT * FROM \"AspNetUsers\" WHERE \"Id\"={id} FOR UPDATE").SingleOrDefaultAsync(ct);
    private static async Task<bool> Fresh(AppDbContext db, HttpContext http, AppUser? user, CancellationToken ct)
    {
        if (!Seller(user) || !user!.EmailConfirmed) return false;
        var now = DateTimeOffset.UtcNow; var sid = http.User.SessionId();
        return await db.AuthSessions.AsNoTracking().AnyAsync(s => s.Id == sid && s.UserId == user.Id && s.RevokedAt == null && s.SecurityStamp == (user.SecurityStamp ?? "") &&
            s.AccessExpiresAt > now && s.CreatedAt <= now && s.CreatedAt >= now.AddMinutes(-15) && (s.AuthMethod == "password_email_otp" || s.AuthMethod == "password_totp"), ct);
    }
    private static IResult FreshRequired() => Results.Problem(statusCode: 403, title: "Đăng nhập lại bằng mật khẩu và mã email/TOTP trước khi quản lý khóa hội thoại bí mật.");
    private static IResult KeysChanged() => Results.Conflict(new { code = "SECRET_KEYS_CHANGED", title = "Thiết bị/khóa đã thay đổi hoặc chưa sẵn sàng. Tải lại và xác minh dấu vân tay khóa trước khi gửi; không tự động đổi khóa." });
    private static bool PublicKey(string value)
    {
        if (value.Length != 44) return false;
        try { var bytes = Convert.FromBase64String(value); return bytes.Length == 32 && bytes.Any(b => b != 0) && Convert.ToBase64String(bytes) == value; }
        catch (FormatException) { return false; }
    }

    private static async Task<IResult> Devices(HttpContext http, AppDbContext db, CancellationToken ct)
    {
        var uid = http.User.UserId();
        var rows = await db.Set<SecretDevice>().AsNoTracking().Where(d => d.UserId == uid).OrderByDescending(d => d.Version).ToListAsync(ct);
        return Results.Ok(new { items = rows.Select(View) });
    }
    private static async Task<IResult> RegisterDevice(RegisterSecretDeviceRequest request, HttpContext http, AppDbContext db, CancellationToken ct)
    {
        await using var tx = await db.Database.BeginTransactionAsync(ct);
        var uid = http.User.UserId(); var user = await UserLock(db, uid, ct);
        if (!await Fresh(db, http, user, ct)) return FreshRequired();
        if (request.DeviceId == Guid.Empty || !Input.Safe(request.Label) || Input.Text(request.Label).Length < 2 || !PublicKey(request.EncryptionPublicKey) || !PublicKey(request.SigningPublicKey)) return Input.Invalid("Cần mã thiết bị, tên và hai khóa công khai base64 chuẩn, mỗi khóa 32 byte.");
        var existing = await db.Set<SecretDevice>().AsNoTracking().SingleOrDefaultAsync(d => d.DeviceId == request.DeviceId, ct);
        if (existing is not null)
        {
            if (existing.UserId == uid && existing.RevokedAt is null && existing.EncryptionPublicKey == request.EncryptionPublicKey && existing.SigningPublicKey == request.SigningPublicKey) return Results.Ok(View(existing));
            return KeysChanged();
        }
        if (await db.Set<SecretDevice>().AnyAsync(d => d.UserId == uid && d.RevokedAt == null, ct)) return KeysChanged();
        var version = (await db.Set<SecretDevice>().Where(d => d.UserId == uid).MaxAsync(d => (int?)d.Version, ct) ?? 0) + 1;
        var device = new SecretDevice { DeviceId = request.DeviceId, UserId = uid, Version = version, Label = Input.Text(request.Label), EncryptionPublicKey = request.EncryptionPublicKey, SigningPublicKey = request.SigningPublicKey };
        db.Add(device); db.AuditEntries.Add(SessionTokens.Audit(uid, uid, "SecretDeviceRegistered", device.DeviceId.ToString()));
        await db.SaveChangesAsync(ct); await tx.CommitAsync(ct);
        return Results.Created($"/api/v1/secret/devices/{device.DeviceId}", View(device));
    }
    private static async Task<IResult> RevokeDevice(Guid deviceId, HttpContext http, AppDbContext db, CancellationToken ct)
    {
        await using var tx = await db.Database.BeginTransactionAsync(ct);
        var uid = http.User.UserId(); var user = await UserLock(db, uid, ct);
        if (!await Fresh(db, http, user, ct)) return FreshRequired();
        var device = await db.Set<SecretDevice>().SingleOrDefaultAsync(d => d.DeviceId == deviceId && d.UserId == uid, ct);
        if (device is null) return Results.NotFound();
        if (device.RevokedAt is null) { device.RevokedAt = DateTimeOffset.UtcNow; db.AuditEntries.Add(SessionTokens.Audit(uid, uid, "SecretDeviceRevoked", deviceId.ToString())); await db.SaveChangesAsync(ct); }
        await tx.CommitAsync(ct); return Results.NoContent();
    }

    private static async Task<Pair?> DirectPair(AppDbContext db, Guid directId, Guid uid, bool locked, CancellationToken ct)
    {
        if (!await db.Conversations.AsNoTracking().AnyAsync(c => c.Id == directId && c.Kind == "Direct", ct)) return null;
        var ids = await db.Participants.AsNoTracking().Where(p => p.ConversationId == directId).Select(p => p.UserId).OrderBy(id => id).ToArrayAsync(ct);
        if (ids.Length != 2 || !ids.Contains(uid)) return null;
        if (locked)
        {
            // User locks precede conversation locks; keys/revocation/account changes take user UPDATE locks.
            foreach (var id in ids.Order())
                if (!Seller(await db.Users.FromSqlInterpolated($"SELECT * FROM \"AspNetUsers\" WHERE \"Id\"={id} FOR SHARE").AsNoTracking().SingleOrDefaultAsync(ct))) return null;
            var direct = await db.Conversations.FromSqlInterpolated($"SELECT * FROM \"Conversations\" WHERE \"Id\"={directId} FOR UPDATE").AsNoTracking().SingleOrDefaultAsync(ct);
            if (direct?.Kind != "Direct") return null;
            var current = await db.Participants.AsNoTracking().Where(p => p.ConversationId == directId).Select(p => p.UserId).OrderBy(id => id).ToArrayAsync(ct);
            if (!current.SequenceEqual(ids)) return null;
        }
        else
        {
            var users = await db.Users.AsNoTracking().Where(u => ids.Contains(u.Id)).ToListAsync(ct);
            if (users.Count != 2 || users.Any(user => !Seller(user))) return null;
        }
        return new(directId, ids[0], ids[1]);
    }
    private static async Task<Context?> Load(AppDbContext db, Guid id, Guid uid, bool locked, CancellationToken ct)
    {
        var thread = await db.Set<SecretConversation>().AsNoTracking().SingleOrDefaultAsync(c => c.Id == id && (c.FirstUserId == uid || c.SecondUserId == uid), ct);
        if (thread is null) return null;
        var members = await DirectPair(db, thread.DirectConversationId, uid, locked, ct);
        if (members is null || members.First != thread.FirstUserId || members.Second != thread.SecondUserId) return null;
        if (locked) thread = await db.Set<SecretConversation>().FromSqlInterpolated($"SELECT * FROM \"SecretConversations\" WHERE \"Id\"={id} FOR UPDATE").SingleAsync(ct);
        return new(thread, members);
    }
    private static Task<List<SecretDevice>> ActiveDevices(AppDbContext db, Pair pair, CancellationToken ct) => db.Set<SecretDevice>().AsNoTracking()
        .Where(d => (d.UserId == pair.First || d.UserId == pair.Second) && d.RevokedAt == null).ToListAsync(ct);
    private static SecretDevice? OwnDevice(IEnumerable<SecretDevice> devices, Guid uid, Guid id) => devices.SingleOrDefault(d => d.UserId == uid && d.DeviceId == id && d.RevokedAt is null);

    private static async Task<IResult> CreateConversation(CreateSecretConversationRequest request, HttpContext http, AppDbContext db, IHubContext<FruitHub> hub, ILoggerFactory logs, CancellationToken ct)
    {
        if (request.DirectConversationId == Guid.Empty) return Input.Invalid("Cần hội thoại Direct hiện có.");
        await using var tx = await db.Database.BeginTransactionAsync(ct); var uid = http.User.UserId();
        var pair = await DirectPair(db, request.DirectConversationId, uid, true, ct);
        if (pair is null) return Results.NotFound();
        var existing = await db.Set<SecretConversation>().AsNoTracking().SingleOrDefaultAsync(c => c.DirectConversationId == pair.DirectId, ct);
        if (existing is not null)
        {
            if (existing.FirstUserId != pair.First || existing.SecondUserId != pair.Second) return Results.NotFound();
            return Results.Ok(View(existing));
        }
        if ((await ActiveDevices(db, pair, ct)).Count != 2) return KeysChanged();
        var thread = new SecretConversation { DirectConversationId = pair.DirectId, FirstUserId = pair.First, SecondUserId = pair.Second };
        db.Add(thread); db.AuditEntries.Add(SessionTokens.Audit(uid, uid, "SecretConversationCreated", thread.Id.ToString()));
        await db.SaveChangesAsync(ct); var view = View(thread); await tx.CommitAsync(ct);
        await Notify(hub, logs, pair, "SecretConversationCreated", new { eventId = Guid.NewGuid(), id = thread.Id, directConversationId = thread.DirectConversationId });
        return Results.Created($"/api/v1/secret/conversations/{thread.Id}", view);
    }
    private static IQueryable<SecretConversation> Visible(AppDbContext db, Guid uid) => db.Set<SecretConversation>().AsNoTracking().Where(c =>
        (c.FirstUserId == uid || c.SecondUserId == uid) && c.DirectConversation.Kind == "Direct" &&
        c.FirstUser.IsActive && c.FirstUser.ApprovalStatus == ApprovalState.Approved && (c.FirstUser.Role == AccountRole.Producer || c.FirstUser.Role == AccountRole.Trader) &&
        c.SecondUser.IsActive && c.SecondUser.ApprovalStatus == ApprovalState.Approved && (c.SecondUser.Role == AccountRole.Producer || c.SecondUser.Role == AccountRole.Trader) &&
        db.Participants.Count(p => p.ConversationId == c.DirectConversationId) == 2 &&
        db.Participants.Any(p => p.ConversationId == c.DirectConversationId && p.UserId == c.FirstUserId) && db.Participants.Any(p => p.ConversationId == c.DirectConversationId && p.UserId == c.SecondUserId));
    private static async Task<IResult> Conversations(int? limit, Guid? after, HttpContext http, AppDbContext db, CancellationToken ct)
    {
        if (!Input.Page(limit, out var size)) return Input.Invalid("limit phải từ 1 đến 50.");
        var query = Visible(db, http.User.UserId());
        if (after.HasValue)
        {
            var anchor = await query.SingleOrDefaultAsync(c => c.Id == after.Value, ct);
            if (anchor is null) return Input.Invalid("Mốc hội thoại không hợp lệ.");
            query = query.Where(c => c.LastActivityAt < anchor.LastActivityAt || (c.LastActivityAt == anchor.LastActivityAt && c.Id.CompareTo(anchor.Id) < 0));
        }
        var rows = await query.OrderByDescending(c => c.LastActivityAt).ThenByDescending(c => c.Id).Take(size + 1).ToListAsync(ct);
        return Results.Ok(new { items = rows.Take(size).Select(View), next = rows.Count > size ? rows[size - 1].Id : (Guid?)null });
    }
    private static async Task<IResult> Detail(Guid id, HttpContext http, AppDbContext db, CancellationToken ct) =>
        await Load(db, id, http.User.UserId(), false, ct) is { } context ? Results.Ok(View(context.Thread)) : Results.NotFound();
    private static async Task<IResult> Bundles(Guid id, HttpContext http, AppDbContext db, CancellationToken ct)
    {
        var context = await Load(db, id, http.User.UserId(), false, ct); if (context is null) return Results.NotFound();
        return Results.Ok(new { conversationId = id, items = (await ActiveDevices(db, context.Members, ct)).Select(View) });
    }

    private static string? RequestHash(SendSecretMessageRequest request)
    {
        if (request.ClientMessageId == Guid.Empty || request.SenderDeviceId == Guid.Empty || request.Envelopes is not { Length: 2 } ||
            request.Envelopes.Any(e => e is null || e.RecipientDeviceId == Guid.Empty || e.CiphertextBase64 is null) || request.Envelopes.Select(e => e.RecipientDeviceId).Distinct().Count() != 2) return null;
        foreach (var envelope in request.Envelopes)
        {
            if (envelope.CiphertextBase64.Length is < 4 or > 21848) return null;
            try { var bytes = Convert.FromBase64String(envelope.CiphertextBase64); if (bytes.Length is < 1 or > 16384 || Convert.ToBase64String(bytes) != envelope.CiphertextBase64) return null; }
            catch (FormatException) { return null; }
        }
        var canonical = request.ClientMessageId.ToString("D") + "\n" + request.SenderDeviceId.ToString("D") + "\n" + string.Join("\n", request.Envelopes.OrderBy(e => e.RecipientDeviceId).Select(e => e.RecipientDeviceId.ToString("D") + ":" + e.CiphertextBase64));
        return Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(canonical)));
    }
    private static async Task<IResult> Send(Guid id, SendSecretMessageRequest request, HttpContext http, AppDbContext db, IHubContext<FruitHub> hub, ILoggerFactory logs, CancellationToken ct)
    {
        var hash = RequestHash(request); if (hash is null) return Input.Invalid("Cần UUID và đúng hai phong bì base64 chuẩn, mỗi bản mã từ 1 đến 16384 byte.");
        await using var tx = await db.Database.BeginTransactionAsync(ct); var uid = http.User.UserId();
        var context = await Load(db, id, uid, true, ct); if (context is null) return Results.NotFound();
        var devices = await ActiveDevices(db, context.Members, ct); var own = OwnDevice(devices, uid, request.SenderDeviceId);
        if (devices.Count != 2 || own is null || !request.Envelopes.Select(e => e.RecipientDeviceId).ToHashSet().SetEquals(devices.Select(d => d.DeviceId))) return KeysChanged();
        var existing = await db.Set<SecretMessage>().AsNoTracking().SingleOrDefaultAsync(m => m.ConversationId == id && m.SenderUserId == uid && m.ClientMessageId == request.ClientMessageId, ct);
        if (existing is not null) return existing.RequestHash == hash ? Results.Ok(await MessageView(db, existing.Id, uid, own.DeviceId, ct)) : Results.Conflict();
        var message = new SecretMessage { ConversationId = id, SenderUserId = uid, SenderDeviceId = own.DeviceId, SenderKeyVersion = own.Version,
            ClientMessageId = request.ClientMessageId, Sequence = ++context.Thread.NextSequence, RequestHash = hash };
        db.Add(message);
        foreach (var envelope in request.Envelopes)
        {
            var target = devices.Single(d => d.DeviceId == envelope.RecipientDeviceId);
            db.Add(new SecretEnvelope { MessageId = message.Id, RecipientUserId = target.UserId, RecipientDeviceId = target.DeviceId, RecipientKeyVersion = target.Version, CiphertextBase64 = envelope.CiphertextBase64 });
        }
        context.Thread.LastActivityAt = message.CreatedAt;
        db.AuditEntries.Add(SessionTokens.Audit(uid, uid, "SecretMessageCreated", message.Id.ToString()));
        await db.SaveChangesAsync(ct); var view = await MessageView(db, message.Id, uid, own.DeviceId, ct); await tx.CommitAsync(ct);
        await Notify(hub, logs, context.Members, "SecretMessageCreated", new { eventId = Guid.NewGuid(), id = message.Id, conversationId = id, sequence = message.Sequence });
        return Results.Created($"/api/v1/secret/conversations/{id}/messages/{message.Id}", view);
    }
    private sealed class MessageRow
    {
        public SecretMessage Message { get; set; } = null!;
        public SecretEnvelope Envelope { get; set; } = null!;
        public string SigningPublicKey { get; set; } = "";
    }
    private static IQueryable<MessageRow> MessageQuery(AppDbContext db, Guid uid, Guid deviceId) =>
        from message in db.Set<SecretMessage>().AsNoTracking()
        join envelope in db.Set<SecretEnvelope>().AsNoTracking() on message.Id equals envelope.MessageId
        join sender in db.Set<SecretDevice>().AsNoTracking() on message.SenderDeviceId equals sender.DeviceId
        where envelope.RecipientUserId == uid && envelope.RecipientDeviceId == deviceId
        select new MessageRow { Message = message, Envelope = envelope, SigningPublicKey = sender.SigningPublicKey };
    private static SecretMessageView MessageView(MessageRow row) => new(row.Message.Id, row.Message.ConversationId, row.Message.Sequence, row.Message.ClientMessageId,
        row.Message.SenderUserId, row.Message.SenderDeviceId, row.Message.SenderKeyVersion, row.SigningPublicKey, row.Message.CreatedAt,
        new SecretEnvelopeView(row.Envelope.RecipientDeviceId, row.Envelope.RecipientKeyVersion, row.Envelope.CiphertextBase64));
    private static async Task<SecretMessageView> MessageView(AppDbContext db, Guid id, Guid uid, Guid deviceId, CancellationToken ct) => MessageView(await MessageQuery(db, uid, deviceId).SingleAsync(row => row.Message.Id == id, ct));
    private static async Task<IResult> Messages(Guid id, Guid deviceId, int? limit, long? beforeSequence, long? afterSequence, HttpContext http, AppDbContext db, CancellationToken ct)
    {
        if (!Input.Page(limit, out var size) || beforeSequence is <= 0 || afterSequence is < 0 || (beforeSequence.HasValue && afterSequence.HasValue)) return Input.Invalid("Giới hạn hoặc mốc phân trang không hợp lệ.");
        var uid = http.User.UserId(); var context = await Load(db, id, uid, false, ct); if (context is null) return Results.NotFound();
        if (OwnDevice(await ActiveDevices(db, context.Members, ct), uid, deviceId) is null) return Results.NotFound();
        var query = MessageQuery(db, uid, deviceId).Where(row => row.Message.ConversationId == id);
        if (beforeSequence.HasValue) query = query.Where(row => row.Message.Sequence < beforeSequence.Value);
        if (afterSequence.HasValue) query = query.Where(row => row.Message.Sequence > afterSequence.Value);
        var rows = afterSequence.HasValue ? await query.OrderBy(row => row.Message.Sequence).Take(size + 1).ToListAsync(ct) : await query.OrderByDescending(row => row.Message.Sequence).Take(size + 1).ToListAsync(ct);
        var items = rows.Take(size).OrderBy(row => row.Message.Sequence).Select(MessageView).ToArray(); var more = rows.Count > size;
        return Results.Ok(new { items, nextBefore = more && !afterSequence.HasValue ? items[0].Sequence : (long?)null,
            nextAfter = more && afterSequence.HasValue ? items[^1].Sequence : (long?)null });
    }

    private static async Task<IResult> Upload(Guid id, Guid senderDeviceId, Guid recipientDeviceId, HttpContext http, AppDbContext db, SecretAttachmentStorage storage, CancellationToken ct)
    {
        var uid = http.User.UserId(); var initial = await Load(db, id, uid, false, ct); if (initial is null) return Results.NotFound();
        var initialDevices = await ActiveDevices(db, initial.Members, ct);
        if (initialDevices.Count != 2 || OwnDevice(initialDevices, uid, senderDeviceId) is null || !initialDevices.Any(d => d.UserId != uid && d.DeviceId == recipientDeviceId)) return KeysChanged();
        if (http.Request.ContentType != "application/octet-stream") return Input.Invalid("Chỉ nhận luồng bản mã application/octet-stream; không gửi ảnh gốc hoặc khóa ảnh.");
        if (http.Request.ContentLength > SecretAttachmentStorage.MaximumBytes) return Results.StatusCode(413);
        var attachment = new SecretAttachment { ConversationId = id, UploaderUserId = uid, SenderDeviceId = senderDeviceId, RecipientDeviceId = recipientDeviceId,
            SenderKeyVersion = initialDevices.Single(d => d.DeviceId == senderDeviceId).Version, RecipientKeyVersion = initialDevices.Single(d => d.DeviceId == recipientDeviceId).Version };
        var committed = false;
        try
        {
            var bodyLimit = http.Features.Get<Microsoft.AspNetCore.Http.Features.IHttpMaxRequestBodySizeFeature>();
            if (bodyLimit is { IsReadOnly: false }) bodyLimit.MaxRequestBodySize = SecretAttachmentStorage.MaximumBytes;
            await storage.SaveAsync(attachment, http.Request.Body, ct);
            // Streaming holds no user/database lock. Recheck and lock identities/keys at commit.
            await using var tx = await db.Database.BeginTransactionAsync(ct);
            var current = await Load(db, id, uid, true, ct); if (current is null) return Results.NotFound();
            var devices = await ActiveDevices(db, current.Members, ct);
            if (devices.Count != 2 || OwnDevice(devices, uid, senderDeviceId) is not { } own || own.Version != attachment.SenderKeyVersion || !devices.Any(d => d.UserId != uid && d.DeviceId == recipientDeviceId && d.Version == attachment.RecipientKeyVersion)) return KeysChanged();
            await MediaStorageQuota.EnsureAsync(db, uid, attachment.SizeBytes, storage.RootPath, http.RequestServices.GetRequiredService<IConfiguration>(), ct);
            db.Add(attachment); db.AuditEntries.Add(SessionTokens.Audit(uid, uid, "SecretAttachmentUploaded", attachment.Id.ToString()));
            await db.SaveChangesAsync(ct);
            var view = new SecretAttachmentView(attachment.Id, attachment.SizeBytes, attachment.Sha256, attachment.CreatedAt,
                $"/api/v1/secret/conversations/{id}/attachments/{attachment.Id}?deviceId={senderDeviceId}");
            await tx.CommitAsync(ct); committed = true;
            return Results.Created(view.DownloadPath, view);
        }
        catch (SecretStorageException error) { return Results.Problem(statusCode: error.Status, title: error.Message); }
        catch (MediaQuotaException error) { return Results.Problem(statusCode: error.Status, title: error.Message, extensions: new Dictionary<string, object?> { ["code"] = "MEDIA_STORAGE_QUOTA" }); }
        finally { if (!committed) storage.Remove(attachment); }
    }
    private static async Task<IResult> Download(Guid id, Guid attachmentId, Guid deviceId, HttpContext http, AppDbContext db, SecretAttachmentStorage storage, CancellationToken ct)
    {
        var uid = http.User.UserId(); var context = await Load(db, id, uid, false, ct); if (context is null) return Results.NotFound();
        var own = OwnDevice(await ActiveDevices(db, context.Members, ct), uid, deviceId); if (own is null) return Results.NotFound();
        var attachment = await db.Set<SecretAttachment>().AsNoTracking().SingleOrDefaultAsync(a => a.Id == attachmentId && a.ConversationId == id, ct);
        if (attachment is null || !((attachment.SenderDeviceId == deviceId && attachment.SenderKeyVersion == own.Version) || (attachment.RecipientDeviceId == deviceId && attachment.RecipientKeyVersion == own.Version))) return Results.NotFound();
        var file = await storage.OpenAsync(attachment, ct); if (file is null) return Results.NotFound();
        return Results.File(file, "application/octet-stream", "encrypted_" + attachment.Id.ToString("N") + ".bin");
    }
    private static async Task Notify(IHubContext<FruitHub> hub, ILoggerFactory logs, Pair pair, string target, object metadata)
    {
        try { await hub.Clients.Groups(new[] { "user:" + pair.First, "user:" + pair.Second }).SendAsync(target, metadata, CancellationToken.None); }
        catch (Exception error) { logs.CreateLogger("SecretMetadataEvents").LogWarning("Secret metadata notification could not be delivered ({FailureType}); REST catchup remains available.", error.GetType().Name); }
    }
}
