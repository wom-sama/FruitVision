using FruitVision.Api.Auth;
using FruitVision.Api.Contracts;
using FruitVision.Api.Data;
using FruitVision.Api.Infrastructure;
using FruitVision.Api.Realtime;
using Microsoft.AspNetCore.SignalR;
using Microsoft.EntityFrameworkCore;

namespace FruitVision.Api.Features;

public static class CommunityEndpoints
{
    public static void MapCommunity(this WebApplication app)
    {
        var routes = app.MapGroup("/api/v1/community").RequireAuthorization("Approved");
        routes.MapGet("/groups", async (string? region, string? productCode, int? limit, Guid? after,
            HttpContext http, AppDbContext db, CancellationToken ct) =>
        {
            if (!Input.Page(limit, out var size)) return Input.Invalid("limit phải từ 1 đến 50.");
            var filters = await CommunityMarketInput.Filters(db, region, productCode, ct);
            if (filters.Error is not null) return Input.Invalid(filters.Error);
            var query = db.Conversations.AsNoTracking().Where(c => c.Kind == "Group" && c.IsOpen);
            if (filters.Region is not null) query = query.Where(c => c.Region != null && c.Region.ToLower() == filters.Region.ToLower());
            if (filters.ProductCode is not null) query = query.Where(c => c.ProductCode == filters.ProductCode);
            if (after.HasValue)
            {
                var anchor = await query.SingleOrDefaultAsync(c => c.Id == after.Value, ct);
                if (anchor is null) return Input.Invalid("Cursor không tồn tại trong danh sách nhóm đang mở.");
                query = query.Where(c => c.CreatedAt < anchor.CreatedAt || (c.CreatedAt == anchor.CreatedAt && c.Id.CompareTo(anchor.Id) < 0));
            }
            var uid = http.User.UserId();
            var rows = await Views(query.OrderByDescending(c => c.CreatedAt).ThenByDescending(c => c.Id).Take(size + 1), db, uid).ToListAsync(ct);
            return Results.Ok(new { items = rows.Take(size), next = rows.Count > size ? rows[size - 1].Id : (Guid?)null });
        });
        routes.MapPost("/groups", async (CreateCommunityGroupRequest request, HttpContext http,
            AppDbContext db, IHubContext<FruitHub> hub, CancellationToken ct) =>
        {
            if (!Input.Safe(request.Title) || Input.Text(request.Title).Length is < 5 or > 160)
                return Input.Invalid("Tên nhóm phải từ 5 đến 160 ký tự hợp lệ.");
            var filters = await CommunityMarketInput.Filters(db, request.Region, request.ProductCode, ct);
            if (filters.Error is not null) return Input.Invalid(filters.Error);
            var uid = http.User.UserId();
            await using var transaction = await db.Database.BeginTransactionAsync(ct);
            var ownerLock = $"community-owner:{uid:N}";
            await db.Database.ExecuteSqlInterpolatedAsync($"SELECT pg_advisory_xact_lock(hashtextextended({ownerLock},0))", ct);
            if (await db.Conversations.CountAsync(c => c.Kind == "Group" && c.IsOpen && c.OwnerId == uid, ct) >= 10)
                return Results.Conflict(new { message = "Mỗi người chỉ được sở hữu tối đa 10 nhóm đang mở." });
            var group = new Conversation { Kind = "Group", OwnerId = uid, Title = Input.Text(request.Title),
                Region = filters.Region, ProductCode = filters.ProductCode, IsOpen = true };
            db.Conversations.Add(group);
            db.Participants.Add(new Participant { ConversationId = group.Id, UserId = uid });
            db.AuditEntries.Add(SessionTokens.Audit(uid, uid, "CommunityGroupCreated"));
            await db.SaveChangesAsync(ct);
            var result = await View(db, group.Id, uid, ct);
            await transaction.CommitAsync(ct);
            await Changed(hub, group.Id, app.Logger, ct);
            await Joined(hub, group.Id, uid, app.Logger, ct);
            return Results.Created($"/api/v1/community/groups/{group.Id}", result);
        }).RequireAuthorization("Admin").AddEndpointFilter<InputFilter>();
        routes.MapGet("/groups/{id:guid}", async (Guid id, HttpContext http, AppDbContext db, CancellationToken ct) =>
        {
            var uid = http.User.UserId();
            var result = await View(db, id, uid, ct);
            if (result is null || (!result.IsOpen && !result.IsMember && result.OwnerId != uid && !http.User.IsInRole("Admin")))
                return Results.NotFound();
            return Results.Ok(result);
        });
        routes.MapPost("/groups/{id:guid}/join", async (Guid id, CommunityActionRequest request,
            HttpContext http, AppDbContext db, IHubContext<FruitHub> hub, CancellationToken ct) =>
        {
            var uid = http.User.UserId();
            await using var transaction = await db.Database.BeginTransactionAsync(ct);
            var group = await LockedGroup(db, id, ct);
            if (group is null) return Results.NotFound();
            if (!group.IsOpen) return Results.Conflict(new { message = "Nhóm đã đóng; không thể tham gia." });
            if (await db.Participants.AnyAsync(p => p.ConversationId == id && p.UserId == uid, ct))
                return Results.Ok(await View(db, id, uid, ct));
            if (await db.Participants.CountAsync(p => p.ConversationId == id, ct) >= 50)
                return Results.Conflict(new { message = "Nhóm đã đủ 50 thành viên." });
            db.Participants.Add(new Participant { ConversationId = id, UserId = uid });
            await db.SaveChangesAsync(ct);
            var result = await View(db, id, uid, ct);
            await transaction.CommitAsync(ct);
            await Changed(hub, id, app.Logger, ct);
            await Joined(hub, id, uid, app.Logger, ct);
            return Results.Created($"/api/v1/community/groups/{id}", result);
        });
        routes.MapPost("/groups/{id:guid}/leave", async (Guid id, CommunityActionRequest request,
            HttpContext http, AppDbContext db, IHubContext<FruitHub> hub, CancellationToken ct) =>
        {
            var uid = http.User.UserId();
            await using var transaction = await db.Database.BeginTransactionAsync(ct);
            var group = await LockedGroup(db, id, ct);
            if (group is null) return Results.NotFound();
            if (group.OwnerId == uid && group.IsOpen)
                return Results.Conflict(new { message = "Chủ nhóm cần đóng nhóm trước khi rời." });
            var membership = await db.Participants.SingleOrDefaultAsync(p => p.ConversationId == id && p.UserId == uid, ct);
            if (membership is null) return Results.Ok(new { id, isMember = false });
            db.Participants.Remove(membership);
            await db.SaveChangesAsync(ct);
            await transaction.CommitAsync(ct);
            await Changed(hub, id, app.Logger, ct);
            return Results.Ok(new { id, isMember = false });
        });
        routes.MapPost("/groups/{id:guid}/close", async (Guid id, CommunityActionRequest request,
            HttpContext http, AppDbContext db, IHubContext<FruitHub> hub, CancellationToken ct) =>
        {
            var uid = http.User.UserId();
            await using var transaction = await db.Database.BeginTransactionAsync(ct);
            var group = await LockedGroup(db, id, ct);
            if (group is null) return Results.NotFound();
            if (!group.IsOpen) return Results.Ok(await View(db, id, uid, ct));
            group.IsOpen = false;
            db.AuditEntries.Add(SessionTokens.Audit(uid, group.OwnerId, "CommunityGroupClosed"));
            await db.SaveChangesAsync(ct);
            var result = await View(db, id, uid, ct);
            await transaction.CommitAsync(ct);
            await Changed(hub, id, app.Logger, ct);
            return Results.Ok(result);
        }).RequireAuthorization("Admin");
    }

    private static IQueryable<CommunityGroupView> Views(IQueryable<Conversation> query, AppDbContext db, Guid uid) =>
        query.Select(c => new CommunityGroupView(c.Id, c.Title, c.Kind, c.OwnerId, c.Region, c.ProductCode, c.IsOpen, c.CreatedAt,
            db.Participants.Count(p => p.ConversationId == c.Id), db.Participants.Any(p => p.ConversationId == c.Id && p.UserId == uid),
            c.OwnerId == uid ? "Owner" : db.Participants.Any(p => p.ConversationId == c.Id && p.UserId == uid) ? "Member" : "NonMember"));

    private static Task<CommunityGroupView?> View(AppDbContext db, Guid id, Guid uid, CancellationToken ct) =>
        Views(db.Conversations.AsNoTracking().Where(c => c.Id == id && c.Kind == "Group"), db, uid).SingleOrDefaultAsync(ct);

    private static async Task<Conversation?> LockedGroup(AppDbContext db, Guid id, CancellationToken ct)
    {
        var key = $"community-group:{id:N}";
        await db.Database.ExecuteSqlInterpolatedAsync($"SELECT pg_advisory_xact_lock(hashtextextended({key},0))", ct);
        return await db.Conversations.FromSqlInterpolated($"SELECT * FROM \"Conversations\" WHERE \"Id\"={id} AND \"Kind\"='Group' FOR UPDATE").SingleOrDefaultAsync(ct);
    }

    private static Task Changed(IHubContext<FruitHub> hub, Guid id, ILogger logger, CancellationToken ct) =>
        Notify(hub, "approved", "CommunityChanged", new { eventId = Guid.NewGuid(), id }, id, logger, ct);
    private static Task Joined(IHubContext<FruitHub> hub, Guid id, Guid uid, ILogger logger, CancellationToken ct) =>
        Notify(hub, $"user:{uid}", "ConversationCreated", new { eventId = Guid.NewGuid(), id, postId = (Guid?)null }, id, logger, ct);

    private static async Task Notify(IHubContext<FruitHub> hub, string audience, string eventName,
        object payload, Guid id, ILogger logger, CancellationToken ct)
    {
        // The membership change is committed. A disconnected caller/backplane must not turn it into a failed write.
        try { await hub.Clients.Group(audience).SendAsync(eventName, payload, ct); }
        catch (Exception exception)
        { logger.LogWarning("Community group {GroupId} notification was not delivered ({FailureType}).", id, exception.GetType().Name); }
    }
}
