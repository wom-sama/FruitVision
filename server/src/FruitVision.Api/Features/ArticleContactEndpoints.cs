using FruitVision.Api.Auth;
using FruitVision.Api.Data;
using FruitVision.Api.Infrastructure;
using FruitVision.Api.Realtime;
using Microsoft.AspNetCore.SignalR;
using Microsoft.EntityFrameworkCore;

namespace FruitVision.Api.Features;

public static class ArticleContactEndpoints
{
    public static void MapArticleContact(this WebApplication app)
    {
        app.MapPost("/api/v1/articles/{id:guid}/conversations", Contact)
            .RequireAuthorization("Approved").AddEndpointFilter<InputFilter>();
    }

    private static async Task<IResult> Contact(Guid id, ArticleContactRequest request, HttpContext http,
        AppDbContext db, IHubContext<FruitHub> hub, ILoggerFactory logs, CancellationToken ct)
    {
        if (http.User.IsInRole("Admin")) return Results.Forbid();
        var uid = http.User.UserId();
        await using var transaction = await db.Database.BeginTransactionAsync(ct);
        var lockKey = $"article-contact:{id:N}:{uid:N}";
        await db.Database.ExecuteSqlInterpolatedAsync($"SELECT pg_advisory_xact_lock(hashtextextended({lockKey},0))", ct);
        var article = await db.Set<CommunityArticle>().FromSqlInterpolated($"SELECT * FROM \"CommunityArticles\" WHERE \"Id\"={id} FOR SHARE").SingleOrDefaultAsync(ct);
        if (article is null || article.Status != "Published") return Results.NotFound();
        var ownerId = article.AuthorId;
        var users = await db.Users.FromSqlInterpolated($"SELECT * FROM \"AspNetUsers\" WHERE \"Id\"={ownerId} OR \"Id\"={uid} ORDER BY \"Id\" FOR SHARE").ToListAsync(ct);
        var author = users.SingleOrDefault(user => user.Id == ownerId);
        var initiator = users.SingleOrDefault(user => user.Id == uid);
        if (author is null || !author.IsActive || author.ApprovalStatus != ApprovalState.Approved) return Results.NotFound();
        if (initiator is null || !initiator.IsActive || initiator.ApprovalStatus != ApprovalState.Approved || initiator.Role == AccountRole.Admin) return Results.Forbid();
        article.Author = author;
        if (article.AudienceLane == "Professional" && article.BranchId.HasValue)
            article.Branch = await db.Set<SellerBranch>().FromSqlInterpolated($"SELECT * FROM \"SellerBranches\" WHERE \"Id\"={article.BranchId.Value} AND \"OwnerId\"={ownerId} FOR SHARE").SingleOrDefaultAsync(ct);
        if (!PublishingEndpoints.IsArticlePublic(article)) return Results.NotFound();
        if (ownerId == uid) return Results.Conflict(new { message = "Không tạo hội thoại với bài viết của chính mình." });
        if (await ProfileBlocks.IsEitherBlockedAsync(db, uid, ownerId, ct)) return Results.NotFound();

        var thread = await db.Conversations.FromSqlInterpolated($"SELECT * FROM \"Conversations\" WHERE \"ArticleId\"={id} AND \"InitiatorId\"={uid} FOR UPDATE").SingleOrDefaultAsync(ct);
        if (thread is not null)
        {
            var members = await db.Participants.Where(p => p.ConversationId == thread.Id).Select(p => p.UserId).ToListAsync(ct);
            if (thread.Kind != "Direct" || thread.PostId.HasValue || thread.OwnerId != ownerId ||
                members.Count != 2 || !members.Contains(ownerId) || !members.Contains(uid)) return Results.NotFound();
            return Results.Ok(View(thread));
        }

        thread = new Conversation { ArticleId = id, InitiatorId = uid, OwnerId = ownerId, Kind = "Direct",
            Title = "Trao đổi bài viết · " + article.Title, Region = article.Branch?.Region ?? author.Region };
        db.Conversations.Add(thread);
        db.Participants.AddRange(new Participant { ConversationId = thread.Id, UserId = ownerId }, new Participant { ConversationId = thread.Id, UserId = uid });
        foreach (var recipient in new[] { ownerId, uid })
            db.InteractionHistories.Add(new InteractionHistory { UserId = recipient, Kind = "ConversationCreated", Title = "Hội thoại từ bài viết",
                Body = $"Đã mở trao đổi riêng về bài viết {article.Title}. Mã hội thoại: {thread.Id}" });
        db.AuditEntries.Add(SessionTokens.Audit(uid, ownerId, "ArticleContactCreated", thread.Id.ToString()));
        await db.SaveChangesAsync(ct); await transaction.CommitAsync(ct);
        try
        {
            await hub.Clients.Groups(new[] { $"user:{ownerId}", $"user:{uid}" }).SendAsync("ConversationCreated",
                new { eventId = Guid.NewGuid(), id = thread.Id, postId = (Guid?)null, articleId = id });
        }
        catch (Exception error)
        { logs.CreateLogger("ArticleContact").LogWarning("Conversation {ConversationId} notification was not delivered ({FailureType}).", thread.Id, error.GetType().Name); }
        return Results.Created($"/api/v1/conversations/{thread.Id}/messages", View(thread));
    }

    private static object View(Conversation conversation) => new
    { conversation.Id, conversation.Title, conversation.PostId, conversation.ArticleId, conversation.Kind, conversation.OwnerId, conversation.IsOpen, conversation.Region, conversation.ProductCode };
}

public sealed record ArticleContactRequest;
