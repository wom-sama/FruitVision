using System.Runtime.CompilerServices;
using FruitVision.Api.Auth;
using FruitVision.Api.Data;
using FruitVision.Api.Infrastructure;
using FruitVision.Api.Realtime;
using Microsoft.AspNetCore.SignalR;
using Microsoft.EntityFrameworkCore;

namespace FruitVision.Api.Features;

public static class InboxEndpoints
{
    public sealed record ReadInboxRequest(Guid? LastMessageId = null, long? LastSecretSequence = null);
    public sealed class SummaryView
    {
        public long UnreadTotal { get; set; }
        public int UnreadConversations { get; set; }
    }
    public sealed class InboxRow
    {
        public Guid Id { get; set; }
        public string Title { get; set; } = "";
        public string Kind { get; set; } = "";
        public bool IsOpen { get; set; }
        public Guid? PostId { get; set; }
        public Guid? ArticleId { get; set; }
        public Guid? OwnerId { get; set; }
        public string? Region { get; set; }
        public string? ProductCode { get; set; }
        public Guid? PeerId { get; set; }
        public string? PeerName { get; set; }
        public string? PeerRole { get; set; }
        public DateTimeOffset LastActivityAt { get; set; }
        public DateTimeOffset? LastMessageCreatedAt { get; set; }
        public string? LastMessageKind { get; set; }
        public string? LastMessageText { get; set; }
        public string? LastSenderName { get; set; }
        public int UnreadCount { get; set; }
        public Guid? SecretConversationId { get; set; }
        public bool LastMessageEncrypted { get; set; }
    }

    // One parameter: the authenticated user UUID. No envelope, ciphertext, key, email or
    // private profile is selected. All totals use fresh participant membership, including
    // conversations beyond the returned page. Indexed lateral lookups fetch only last rows.
    private const string Core = """
        WITH mine AS (
          SELECT c.*, r."LastNormalCreatedAt", r."LastNormalMessageId", r."LastSecretSequence"
          FROM "Conversations" c JOIN "Participants" p ON p."ConversationId"=c."Id" AND p."UserId"={0}
          LEFT JOIN "ConversationReadStates" r ON r."ConversationId"=c."Id" AND r."UserId"={0}
        ), eligible AS (
          SELECT s.* FROM "SecretConversations" s JOIN mine c ON c."Id"=s."DirectConversationId"
          JOIN "AspNetUsers" a ON a."Id"=s."FirstUserId" JOIN "AspNetUsers" b ON b."Id"=s."SecondUserId"
          WHERE c."Kind"='Direct' AND a."IsActive" AND b."IsActive"
            AND a."ApprovalStatus"='Approved' AND b."ApprovalStatus"='Approved'
            AND a."Role" IN ('Producer','Trader') AND b."Role" IN ('Producer','Trader')
            AND (a."LockoutEnd" IS NULL OR a."LockoutEnd"<=CURRENT_TIMESTAMP)
            AND (b."LockoutEnd" IS NULL OR b."LockoutEnd"<=CURRENT_TIMESTAMP)
            AND (SELECT COUNT(*) FROM "Participants" p WHERE p."ConversationId"=c."Id")=2
            AND EXISTS(SELECT 1 FROM "Participants" p WHERE p."ConversationId"=c."Id" AND p."UserId"=s."FirstUserId")
            AND EXISTS(SELECT 1 FROM "Participants" p WHERE p."ConversationId"=c."Id" AND p."UserId"=s."SecondUserId")
        ), activity AS (
          SELECT c.*, peer."Id" AS "PeerId", peer."DisplayName" AS "PeerName", peer."Role" AS "PeerRole",
            n."Id" AS "NormalId", n."CreatedAt" AS "NormalTime", n."Text" AS "NormalText",
            n."NormalImageId", n."SenderName" AS "NormalSender",
            s."Id" AS "SecretConversationId", e."Id" AS "SecretMessageId", e."CreatedAt" AS "SecretTime", e."SenderName" AS "SecretSender",
            ((SELECT COUNT(*) FROM "Messages" m WHERE m."ConversationId"=c."Id" AND m."SenderId"<>{0}
                AND (c."LastNormalCreatedAt" IS NULL OR (m."CreatedAt",m."Id")>(c."LastNormalCreatedAt",c."LastNormalMessageId")))
             +(SELECT COUNT(*) FROM "SecretMessages" m WHERE m."ConversationId"=s."Id" AND m."SenderUserId"<>{0}
                AND m."Sequence">COALESCE(c."LastSecretSequence",0)))::integer AS "UnreadCount"
          FROM mine c LEFT JOIN eligible s ON s."DirectConversationId"=c."Id"
          LEFT JOIN LATERAL (SELECT m."Id",m."CreatedAt",m."Text",m."NormalImageId",u."DisplayName" AS "SenderName"
              FROM "Messages" m JOIN "AspNetUsers" u ON u."Id"=m."SenderId" WHERE m."ConversationId"=c."Id"
              ORDER BY m."CreatedAt" DESC,m."Id" DESC LIMIT 1) n ON TRUE
          LEFT JOIN LATERAL (SELECT m."Id",m."CreatedAt",u."DisplayName" AS "SenderName"
              FROM "SecretMessages" m JOIN "AspNetUsers" u ON u."Id"=m."SenderUserId" WHERE m."ConversationId"=s."Id"
              ORDER BY m."CreatedAt" DESC,m."Id" DESC LIMIT 1) e ON TRUE
          LEFT JOIN LATERAL (SELECT u."Id",u."DisplayName",u."Role" FROM "Participants" p JOIN "AspNetUsers" u ON u."Id"=p."UserId"
              WHERE p."ConversationId"=c."Id" AND p."UserId"<>{0} AND c."Kind"='Direct'
                AND (SELECT COUNT(*) FROM "Participants" p2 WHERE p2."ConversationId"=c."Id")=2 LIMIT 1) peer ON TRUE
        ), chosen AS (
          SELECT *, ("SecretTime" IS NOT NULL AND ("NormalTime" IS NULL OR ("SecretTime","SecretMessageId")>("NormalTime","NormalId"))) AS "Encrypted"
          FROM activity
        )
        SELECT "Id","Title","Kind","IsOpen","PostId","ArticleId","OwnerId","Region","ProductCode","PeerId","PeerName","PeerRole",
          COALESCE(GREATEST("NormalTime","SecretTime"),"CreatedAt") AS "LastActivityAt",
          CASE WHEN "Encrypted" THEN "SecretTime" ELSE "NormalTime" END AS "LastMessageCreatedAt",
          CASE WHEN "Encrypted" THEN 'encrypted' WHEN "NormalId" IS NULL THEN NULL WHEN "NormalImageId" IS NOT NULL THEN 'image' ELSE 'text' END AS "LastMessageKind",
          CASE WHEN "Encrypted" THEN 'Tin nhắn mã hóa' WHEN "NormalImageId" IS NOT NULL THEN 'Ảnh' ELSE LEFT("NormalText",200) END AS "LastMessageText",
          CASE WHEN "Encrypted" THEN "SecretSender" ELSE "NormalSender" END AS "LastSenderName",
          "UnreadCount","SecretConversationId","Encrypted" AS "LastMessageEncrypted"
        FROM chosen
        """;

    private static IQueryable<InboxRow> Rows(AppDbContext db, Guid uid) => db.Database.SqlQuery<InboxRow>(FormattableStringFactory.Create(Core, uid));
    private static Task<SummaryView> Summary(AppDbContext db, Guid uid, CancellationToken ct) => db.Database.SqlQuery<SummaryView>(
        FormattableStringFactory.Create("SELECT COALESCE(SUM(\"UnreadCount\"),0)::bigint AS \"UnreadTotal\", COUNT(*) FILTER (WHERE \"UnreadCount\">0)::integer AS \"UnreadConversations\" FROM (" + Core + ") inbox", uid)).SingleAsync(ct);

    public static void MapInbox(this WebApplication app)
    {
        app.MapGet("/api/v1/conversations/summary", async (HttpContext http, AppDbContext db, CancellationToken ct) => Results.Ok(await Summary(db, http.User.UserId(), ct))).RequireAuthorization("Approved");
        app.MapPost("/api/v1/conversations/{id:guid}/read", Read).RequireAuthorization("Approved");
    }

    public static async Task<IResult> List(HttpContext http, int? limit, AppDbContext db, CancellationToken ct)
    {
        if (!Input.Page(limit, out var size)) return Input.Invalid("limit phải từ 1 đến 50.");
        var uid = http.User.UserId();
        var rows = await Rows(db, uid).OrderByDescending(r => r.LastActivityAt).ThenByDescending(r => r.Id).Take(size).ToListAsync(ct);
        var summary = await Summary(db, uid, ct);
        return Results.Ok(new { items = rows.Select(row => new { row.Id, row.Title, row.Kind, row.IsOpen, row.PostId, row.ArticleId, row.OwnerId, row.Region, row.ProductCode,
            peer = row.PeerId.HasValue ? new { id = row.PeerId.Value, displayName = row.PeerName, role = row.PeerRole } : null,
            row.LastActivityAt, lastMessage = row.LastMessageCreatedAt.HasValue ? new { kind = row.LastMessageKind, text = row.LastMessageText, senderName = row.LastSenderName, createdAt = row.LastMessageCreatedAt.Value } : null,
            row.UnreadCount, row.SecretConversationId, row.LastMessageEncrypted }), summary });
    }

    private static async Task<IResult> Read(Guid id, ReadInboxRequest request, HttpContext http, AppDbContext db, IHubContext<FruitHub> hub, ILoggerFactory logs, CancellationToken ct)
    {
        if ((!request.LastMessageId.HasValue && !request.LastSecretSequence.HasValue) || request.LastMessageId == Guid.Empty || request.LastSecretSequence is <= 0)
            return Input.Invalid("Cần cursor của tin nhắn thực sự đã hiển thị.");
        var uid = http.User.UserId(); await using var tx = await db.Database.BeginTransactionAsync(ct);
        var conversation = await db.Conversations.FromSqlInterpolated($"SELECT * FROM \"Conversations\" WHERE \"Id\"={id} FOR UPDATE").AsNoTracking().SingleOrDefaultAsync(ct);
        if (conversation is null || !await db.Participants.AnyAsync(p => p.ConversationId == id && p.UserId == uid, ct)) return Results.NotFound();
        Message? displayed = null;
        if (request.LastMessageId.HasValue)
        {
            displayed = await db.Messages.AsNoTracking().SingleOrDefaultAsync(m => m.ConversationId == id && m.Id == request.LastMessageId.Value, ct);
            if (displayed is null) return Input.Invalid("Tin nhắn không thuộc hội thoại này.");
        }
        if (request.LastSecretSequence.HasValue)
        {
            var owned = await Rows(db, uid).SingleAsync(r => r.Id == id, ct);
            if (!owned.SecretConversationId.HasValue || !await db.Set<SecretMessage>().AnyAsync(m => m.ConversationId == owned.SecretConversationId.Value && m.Sequence == request.LastSecretSequence.Value, ct))
                return Input.Invalid("Cursor secret không tồn tại hoặc hội thoại không còn đủ điều kiện.");
        }
        var state = await db.Set<ConversationReadState>().SingleOrDefaultAsync(s => s.ConversationId == id && s.UserId == uid, ct);
        if (state is null) { state = new ConversationReadState { ConversationId = id, UserId = uid }; db.Add(state); }
        if (displayed is not null && (!state.LastNormalCreatedAt.HasValue || displayed.CreatedAt > state.LastNormalCreatedAt.Value ||
            (displayed.CreatedAt == state.LastNormalCreatedAt.Value && displayed.Id.CompareTo(state.LastNormalMessageId!.Value) > 0)))
        { state.LastNormalCreatedAt = displayed.CreatedAt; state.LastNormalMessageId = displayed.Id; }
        if (request.LastSecretSequence.HasValue && request.LastSecretSequence.Value > state.LastSecretSequence) state.LastSecretSequence = request.LastSecretSequence.Value;
        await db.SaveChangesAsync(ct);
        var unread = (await Rows(db, uid).SingleAsync(r => r.Id == id, ct)).UnreadCount;
        await tx.CommitAsync(ct);
        try { await hub.Clients.Group($"user:{uid}").SendAsync("InboxChanged", new { eventId = Guid.NewGuid(), id }); }
        catch (Exception exception) { logs.CreateLogger("Inbox").LogWarning("Inbox {ConversationId} notification was not delivered ({FailureType}).", id, exception.GetType().Name); }
        return Results.Ok(new { id, unreadCount = unread });
    }
}
