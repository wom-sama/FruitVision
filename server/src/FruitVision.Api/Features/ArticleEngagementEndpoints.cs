using FruitVision.Api.Auth;
using FruitVision.Api.Contracts;
using FruitVision.Api.Data;
using FruitVision.Api.Infrastructure;
using FruitVision.Api.Realtime;
using Microsoft.AspNetCore.SignalR;
using Microsoft.EntityFrameworkCore;

namespace FruitVision.Api.Features;

public static class ArticleEngagementEndpoints
{
    public static void MapArticleEngagement(this WebApplication app)
    {
        var articles = app.MapGroup("/api/v1/articles").WithTags("Lượt thích và bình luận bài viết").AddEndpointFilter<InputFilter>();
        articles.MapGet("/{id:guid}/likes", Likes);
        articles.MapPut("/{id:guid}/like", SetLike).RequireAuthorization("Approved");
        articles.MapGet("/{id:guid}/comments", Comments);
        articles.MapPost("/{id:guid}/comments", CreateComment).RequireAuthorization("Approved");
        articles.MapDelete("/{id:guid}/comments/{commentId:guid}", DeleteComment).RequireAuthorization("Approved");
    }

    private static Guid? Reader(HttpContext http) => http.User.Identity?.IsAuthenticated == true ? http.User.UserId() : null;
    private static bool ApprovedReader(HttpContext http) => http.User.Identity?.IsAuthenticated == true && http.User.HasClaim("approval", "Approved");
    private static bool Eligible(AppUser user) => user.IsActive && user.ApprovalStatus == ApprovalState.Approved && !(user.LockoutEnd > DateTimeOffset.UtcNow);
    private static Task<CommunityArticle?> ReadArticle(AppDbContext db, Guid id, CancellationToken ct) => db.Set<CommunityArticle>().AsNoTracking()
        .Include(a => a.Author).Include(a => a.Branch).SingleOrDefaultAsync(a => a.Id == id, ct);

    private static async Task<ArticleEngagementView> Counts(AppDbContext db, Guid id, Guid? uid, CancellationToken ct) => new(id,
        await db.Set<ArticleLike>().CountAsync(l => l.ArticleId == id, ct),
        await db.Set<ArticleComment>().CountAsync(c => c.ArticleId == id && c.Body != "", ct),
        uid.HasValue && await db.Set<ArticleLike>().AnyAsync(l => l.ArticleId == id && l.UserId == uid.Value, ct));

    private static async Task<IResult> Likes(Guid id, HttpContext http, AppDbContext db, CancellationToken ct)
    {
        var article = await ReadArticle(db, id, ct);
        if (article is null || !PublishingEndpoints.IsArticlePublic(article)) return Results.NotFound();
        return Results.Ok(await Counts(db, id, Reader(http), ct));
    }

    // Same lock order as publication review: article first, users in UUID order, then branch.
    // Holding these through commit prevents a publication/author/branch change admitting a write.
    private static async Task<(CommunityArticle? Article, AppUser? Actor)> LockContext(AppDbContext db, Guid id, Guid uid, CancellationToken ct)
    {
        var article = await db.Set<CommunityArticle>().FromSqlInterpolated($"SELECT * FROM \"CommunityArticles\" WHERE \"Id\"={id} FOR UPDATE").SingleOrDefaultAsync(ct);
        if (article is null) return (null, null);
        var authorId = article.AuthorId;
        var users = await db.Users.FromSqlInterpolated($"SELECT * FROM \"AspNetUsers\" WHERE \"Id\"={uid} OR \"Id\"={authorId} ORDER BY \"Id\" FOR SHARE").ToListAsync(ct);
        var actor = users.SingleOrDefault(u => u.Id == uid); var author = users.SingleOrDefault(u => u.Id == authorId);
        if (author is null) return (null, actor);
        article.Author = author;
        if (article.BranchId.HasValue)
            article.Branch = await db.Set<SellerBranch>().FromSqlInterpolated($"SELECT * FROM \"SellerBranches\" WHERE \"Id\"={article.BranchId.Value} FOR SHARE").SingleOrDefaultAsync(ct);
        return (PublishingEndpoints.IsArticlePublic(article) ? article : null, actor);
    }

    private static async Task<IResult> SetLike(Guid id, SetArticleLikeRequest request, HttpContext http, AppDbContext db,
        IHubContext<FruitHub> hub, ILoggerFactory logs, CancellationToken ct)
    {
        var uid = http.User.UserId(); await using var tx = await db.Database.BeginTransactionAsync(ct);
        var context = await LockContext(db, id, uid, ct);
        if (context.Article is null) return Results.NotFound();
        if (context.Actor is null || !Eligible(context.Actor)) return Results.Forbid();
        var previous = await db.Set<ArticleLike>().SingleOrDefaultAsync(l => l.ArticleId == id && l.UserId == uid, ct);
        var changed = request.Liked != (previous is not null);
        if (changed)
        {
            if (request.Liked) db.Add(new ArticleLike { ArticleId = id, UserId = uid }); else db.Remove(previous!);
            await db.SaveChangesAsync(ct);
        }
        var result = await Counts(db, id, uid, ct); await tx.CommitAsync(ct);
        if (changed) await Notify(hub, logs, context.Article);
        return Results.Ok(result);
    }

    private static async Task<IResult> Comments(Guid id, int? limit, Guid? after, HttpContext http, AppDbContext db, CancellationToken ct)
    {
        if (!Input.Page(limit, out var size)) return Input.Invalid("limit phải từ 1 đến 50.");
        var article = await ReadArticle(db, id, ct);
        if (article is null || !PublishingEndpoints.IsArticlePublic(article)) return Results.NotFound();
        var query = db.Set<ArticleComment>().AsNoTracking().Where(c => c.ArticleId == id && c.Body != "");
        if (after.HasValue)
        {
            var anchor = await query.SingleOrDefaultAsync(c => c.Id == after.Value, ct);
            if (anchor is null) return Input.Invalid("Mốc bình luận không thuộc bài viết này.");
            query = query.Where(c => c.CreatedAt < anchor.CreatedAt || (c.CreatedAt == anchor.CreatedAt && c.Id.CompareTo(anchor.Id) < 0));
        }
        var rows = await (from comment in query
                          join author in db.Users.AsNoTracking() on comment.UserId equals author.Id
                          orderby comment.CreatedAt descending, comment.Id descending
                          select new { Comment = comment, author.DisplayName, author.Role }).Take(size + 1).ToListAsync(ct);
        var uid = Reader(http); var approved = ApprovedReader(http); var admin = approved && http.User.IsInRole("Admin");
        var counts = await Counts(db, id, uid, ct);
        return Results.Ok(new { items = rows.Take(size).Select(row => View(row.Comment, row.DisplayName, row.Role, approved && (admin || row.Comment.UserId == uid))),
            next = rows.Count > size ? rows[size - 1].Comment.Id : (Guid?)null, counts.LikeCount, counts.CommentCount, counts.Liked });
    }

    private static ArticleCommentView View(ArticleComment comment, string displayName, AccountRole role, bool canDelete) => new(comment.Id,
        comment.ArticleId, comment.ClientCommentId, comment.Body, comment.CreatedAt, new(comment.UserId, displayName, role.ToString()), canDelete);

    private static async Task<IResult> CreateComment(Guid id, CreateArticleCommentRequest request, HttpContext http, AppDbContext db,
        IHubContext<FruitHub> hub, ILoggerFactory logs, CancellationToken ct)
    {
        if (request.ClientCommentId == Guid.Empty || !Input.Safe(request.Body, true) || Input.Text(request.Body).Length is < 2 or > 1000)
            return Input.Invalid("Bình luận cần 2–1000 ký tự hợp lệ và clientCommentId UUID khác rỗng.");
        var body = Input.Text(request.Body); var uid = http.User.UserId();
        await using var tx = await db.Database.BeginTransactionAsync(ct);
        var context = await LockContext(db, id, uid, ct);
        if (context.Article is null) return Results.NotFound();
        if (context.Actor is null || !Eligible(context.Actor)) return Results.Forbid();
        var previous = await db.Set<ArticleComment>().SingleOrDefaultAsync(c => c.ArticleId == id && c.UserId == uid && c.ClientCommentId == request.ClientCommentId, ct);
        if (previous is not null)
        {
            if (previous.Body.Length == 0) return Results.Conflict(new { message = "Bình luận đã xóa; không gửi lại với clientCommentId cũ." });
            if (previous.Body != body) return Results.Conflict(new { message = "clientCommentId đã dùng cho nội dung khác." });
            return Results.Ok(View(previous, context.Actor.DisplayName, context.Actor.Role, true));
        }
        var comment = new ArticleComment { ArticleId = id, UserId = uid, ClientCommentId = request.ClientCommentId, Body = body };
        db.Add(comment); await db.SaveChangesAsync(ct);
        var result = View(comment, context.Actor.DisplayName, context.Actor.Role, true); await tx.CommitAsync(ct);
        await Notify(hub, logs, context.Article);
        return Results.Created($"/api/v1/articles/{id}/comments/{comment.Id}", result);
    }

    private static async Task<IResult> DeleteComment(Guid id, Guid commentId, HttpContext http, AppDbContext db,
        IHubContext<FruitHub> hub, ILoggerFactory logs, CancellationToken ct)
    {
        var uid = http.User.UserId(); await using var tx = await db.Database.BeginTransactionAsync(ct);
        var context = await LockContext(db, id, uid, ct);
        if (context.Article is null) return Results.NotFound();
        if (context.Actor is null || !Eligible(context.Actor)) return Results.Forbid();
        var comment = await db.Set<ArticleComment>().SingleOrDefaultAsync(c => c.Id == commentId && c.ArticleId == id, ct);
        if (comment is null) return Results.NotFound();
        if (comment.UserId != uid && context.Actor.Role != AccountRole.Admin) return Results.Forbid();
        // Empty body is an internal deletion marker: valid incoming comments require at least
        // two characters. Preserve the unique retry key while clearing the current stored text.
        var changed = comment.Body.Length > 0;
        if (changed)
        {
            comment.Body = "";
            db.AuditEntries.Add(SessionTokens.Audit(uid, comment.UserId, "ArticleCommentDeleted", comment.Id.ToString()));
            await db.SaveChangesAsync(ct);
        }
        await tx.CommitAsync(ct);
        if (changed) await Notify(hub, logs, context.Article);
        return Results.NoContent();
    }

    private static async Task Notify(IHubContext<FruitHub> hub, ILoggerFactory logs, CommunityArticle article)
    {
        try
        {
            await hub.Clients.Groups(new[] { "approved", $"user:{article.AuthorId}", "role:Admin" }).SendAsync("ArticleChanged",
                new { eventId = Guid.NewGuid(), id = article.Id, status = article.Status, revision = article.Revision });
        }
        catch (Exception exception)
        { logs.CreateLogger("ArticleEngagement").LogWarning("Article {ArticleId} engagement notification was not delivered ({FailureType}).", article.Id, exception.GetType().Name); }
    }
}
