using FruitVision.Api.Auth;
using FruitVision.Api.Data;
using Microsoft.EntityFrameworkCore;

namespace FruitVision.Api.Features;

public static class ConversationContextEndpoints
{
    public static void MapConversationContext(this WebApplication app)
    {
        app.MapGet("/api/v1/conversations/{id:guid}/context", Read).RequireAuthorization("Approved");
    }

    private static async Task<IResult> Read(Guid id, HttpContext http, AppDbContext db, CancellationToken ct)
    {
        var uid = http.User.UserId();
        await using var transaction = await db.Database.BeginTransactionAsync(ct);
        // Group join/leave also lock this row; hold a stable membership snapshot through the read.
        var conversation = await db.Conversations.FromSqlInterpolated($"SELECT * FROM \"Conversations\" WHERE \"Id\"={id} FOR SHARE").AsNoTracking().SingleOrDefaultAsync(ct);
        if (conversation is null || !await db.Participants.AnyAsync(p => p.ConversationId == id && p.UserId == uid, ct)) return Results.NotFound();
        if (conversation.Kind == "Group")
            return Results.Ok(new { kind = conversation.Kind, title = conversation.Title, peer = (object?)null, secretEligible = false });
        if (conversation.Kind != "Direct") return Results.NotFound();

        var members = await (from member in db.Participants.AsNoTracking()
                             join user in db.Users.AsNoTracking() on member.UserId equals user.Id
                             where member.ConversationId == id
                             select new { user.Id, user.DisplayName, user.Role, user.IsActive, user.ApprovalStatus }).ToListAsync(ct);
        if (members.Count != 2 || members.Select(m => m.Id).Distinct().Count() != 2 || !members.Any(m => m.Id == uid)) return Results.NotFound();
        var other = members.Single(m => m.Id != uid);
        var eligible = members.All(m => m.IsActive && m.ApprovalStatus == ApprovalState.Approved && m.Role is AccountRole.Producer or AccountRole.Trader);
        return Results.Ok(new { kind = conversation.Kind, title = conversation.Title,
            peer = new { id = other.Id, displayName = other.DisplayName, role = other.Role.ToString() }, secretEligible = eligible });
    }
}
