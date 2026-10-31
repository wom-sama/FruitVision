using System.Buffers.Binary;
using System.Security.Cryptography;
using System.Text;
using FruitVision.Api.Auth;
using FruitVision.Api.Data;
using FruitVision.Api.Infrastructure;
using FruitVision.Api.Realtime;
using Microsoft.AspNetCore.SignalR;
using Microsoft.EntityFrameworkCore;

namespace FruitVision.Api.Features;

public static class DirectContactsEndpoints
{
    public static void MapDirectContacts(this WebApplication app)
    {
        app.MapGet("/api/v1/contacts", async (string? search, int? limit, HttpContext http, AppDbContext db, CancellationToken ct) =>
        {
            if (!Input.Page(limit, out var size) || (search?.Length ?? 0) > 80 || !Input.Safe(search ?? "")) return Input.Invalid("Tìm kiếm tối đa80 ký tự; limit từ1 đến50.");
            var uid = http.User.UserId(); var term = Input.Text(search ?? "");
            var query = db.Users.AsNoTracking().Where(u => u.Id != uid && u.IsActive && u.ApprovalStatus == ApprovalState.Approved &&
                !db.Set<UserBlock>().Any(b => (b.OwnerUserId == uid && b.BlockedUserId == u.Id) || (b.OwnerUserId == u.Id && b.BlockedUserId == uid)));
            if (term.Length > 0)
            {
                var pattern = "%" + term.Replace("\\", "\\\\").Replace("%", "\\%").Replace("_", "\\_") + "%";
                query = query.Where(u => EF.Functions.ILike(u.DisplayName, pattern, "\\"));
            }
            var users = await query.OrderBy(u => u.DisplayName).ThenBy(u => u.Id).Take(size).Select(u => new { u.Id, u.DisplayName, u.Role }).ToListAsync(ct);
            return Results.Ok(new { items = users.Select(u => new { u.Id, u.DisplayName, role = u.Role.ToString() }) });
        }).RequireAuthorization("Approved");
        app.MapPost("/api/v1/conversations/direct", Create).RequireAuthorization("Approved").AddEndpointFilter<InputFilter>();
    }

    private static bool Eligible(AppUser? user) => user is { IsActive: true, ApprovalStatus: ApprovalState.Approved };
    private static long PairLock(Guid first, Guid second)
    {
        var pair = new[] { first.ToString("N"), second.ToString("N") }.Order(StringComparer.Ordinal);
        var hash = SHA256.HashData(Encoding.UTF8.GetBytes("FVDirectv1:" + string.Join(":", pair)));
        return BinaryPrimitives.ReadInt64BigEndian(hash.AsSpan(0, 8));
    }
    private static async Task<IResult> Create(CreateDirectContactRequest request, HttpContext http, AppDbContext db,
        IHubContext<FruitHub> hub, ILoggerFactory logs, CancellationToken ct)
    {
        var uid = http.User.UserId(); var other = request.UserId;
        if (other == Guid.Empty || other == uid) return Input.Invalid("Chọn một tài khoản khác để mở hội thoại.");
        await using var transaction = await db.Database.BeginTransactionAsync(ct);
        var pairLock = PairLock(uid, other);
        await db.Database.ExecuteSqlInterpolatedAsync($"SELECT pg_advisory_xact_lock({pairLock})", ct);
        var users = await db.Users.FromSqlInterpolated($"SELECT * FROM \"AspNetUsers\" WHERE \"Id\"={uid} OR \"Id\"={other} ORDER BY \"Id\" FOR SHARE").ToListAsync(ct);
        if (!Eligible(users.SingleOrDefault(u => u.Id == uid))) return Results.Forbid();
        if (!Eligible(users.SingleOrDefault(u => u.Id == other))) return Results.NotFound();
        if (await ProfileBlocks.IsEitherBlockedAsync(db, uid, other, ct)) return Results.NotFound();
        var existing = await db.Conversations.AsNoTracking().Where(c => c.Kind == "Direct" && c.PostId == null && c.ArticleId == null &&
            db.Participants.Count(p => p.ConversationId == c.Id) == 2 &&
            db.Participants.Any(p => p.ConversationId == c.Id && p.UserId == uid) && db.Participants.Any(p => p.ConversationId == c.Id && p.UserId == other))
            .OrderBy(c => c.CreatedAt).ThenBy(c => c.Id).Select(c => (Guid?)c.Id).FirstOrDefaultAsync(ct);
        if (existing.HasValue)
        {
            var thread = await db.Conversations.FromSqlInterpolated($"SELECT * FROM \"Conversations\" WHERE \"Id\"={existing.Value} FOR SHARE").SingleAsync(ct);
            var members = await db.Participants.FromSqlInterpolated($"SELECT * FROM \"Participants\" WHERE \"ConversationId\"={thread.Id} FOR SHARE").AsNoTracking().ToListAsync(ct);
            if (members.Count != 2 || !members.Any(p => p.UserId == uid) || !members.Any(p => p.UserId == other)) return Results.NotFound();
            return Results.Ok(View(thread));
        }
        var created = new Conversation { Title = "Cuộc trò chuyện riêng", Kind = "Direct", OwnerId = uid, InitiatorId = uid };
        db.Conversations.Add(created); db.Participants.AddRange(new Participant { ConversationId = created.Id, UserId = uid }, new Participant { ConversationId = created.Id, UserId = other });
        db.AuditEntries.Add(SessionTokens.Audit(uid, other, "DirectConversationCreated", created.Id.ToString()));
        await db.SaveChangesAsync(ct); await transaction.CommitAsync(ct);
        try
        {
            await hub.Clients.Groups(new[] { $"user:{uid}", $"user:{other}" }).SendAsync("ConversationCreated",
                new { eventId = Guid.NewGuid(), id = created.Id, postId = (Guid?)null, articleId = (Guid?)null });
        }
        catch (Exception error)
        { logs.CreateLogger("DirectContacts").LogWarning("Conversation {ConversationId} notification was not delivered ({FailureType}).", created.Id, error.GetType().Name); }
        return Results.Created($"/api/v1/conversations/{created.Id}/messages", View(created));
    }
    private static object View(Conversation conversation) => new
    { conversation.Id, conversation.Title, conversation.Kind, conversation.PostId, conversation.ArticleId, conversation.OwnerId, conversation.InitiatorId, conversation.IsOpen };
}

public sealed record CreateDirectContactRequest(Guid UserId);
