using FruitVision.Api.Auth;
using FruitVision.Api.Contracts;
using FruitVision.Api.Data;
using FruitVision.Api.Infrastructure;
using FruitVision.Api.Realtime;
using Microsoft.AspNetCore.SignalR;
using Microsoft.EntityFrameworkCore;

namespace FruitVision.Api.Features;

public static class PostWorkflowEndpoints
{
    private static readonly string[] ReviewStatuses = ["AwaitingReview", "Published", "Rejected", "Paused"];

    public static void MapPostWorkflow(this WebApplication app)
    {
        app.MapGet("/api/v1/posts", async (int? limit, Guid? after, AppDbContext db, CancellationToken cancellationToken) =>
            await Page(db.Posts.AsNoTracking().Where(post => post.Status == "Published" && post.Author.IsActive &&
                post.Author.ApprovalStatus == ApprovalState.Approved), limit, after, false, cancellationToken));
        app.MapGet("/api/v1/posts/{id:guid}", async (Guid id, HttpContext http, AppDbContext db, CancellationToken cancellationToken) =>
        {
            var post = await db.Posts.AsNoTracking().Include(item => item.Author).SingleOrDefaultAsync(item => item.Id == id, cancellationToken);
            if (post is null) return Results.NotFound();
            var privateView = http.User.Identity?.IsAuthenticated == true &&
                (http.User.UserId() == post.AuthorId || (http.User.IsInRole("Admin") && http.User.HasClaim("approval", "Approved")));
            if (!privateView && !Visible(post)) return Results.NotFound();
            return Results.Ok(View(post, privateView));
        });
        app.MapGet("/api/v1/me/posts", async (HttpContext http, int? limit, Guid? after, AppDbContext db, CancellationToken cancellationToken) =>
            await Page(db.Posts.AsNoTracking().Where(post => post.AuthorId == http.User.UserId()), limit, after, true, cancellationToken)).RequireAuthorization();
        app.MapPost("/api/v1/posts", Submit).RequireAuthorization("Seller").AddEndpointFilter<InputFilter>();
        app.MapGet("/api/v1/admin/posts", async (string? status, int? limit, Guid? after, AppDbContext db, CancellationToken cancellationToken) =>
        {
            if (status is not null && !ReviewStatuses.Contains(status)) return Input.Invalid("Trạng thái tin không hợp lệ.");
            var query = db.Posts.AsNoTracking().Where(post => ReviewStatuses.Contains(post.Status));
            if (status is not null) query = query.Where(post => post.Status == status);
            return await Page(query, limit, after, true, cancellationToken);
        }).RequireAuthorization("Admin");
        app.MapPost("/api/v1/admin/posts/{id:guid}/review", Review).RequireAuthorization("Admin").AddEndpointFilter<InputFilter>();
        app.MapPost("/api/v1/posts/{id:guid}/conversations", Contact).RequireAuthorization("Approved").AddEndpointFilter<InputFilter>();
    }

    private static bool Visible(Post post) => post.Status == "Published" && post.Author.IsActive && post.Author.ApprovalStatus == ApprovalState.Approved;

    private static async Task<IResult> Page(IQueryable<Post> query, int? limit, Guid? after, bool privateView, CancellationToken cancellationToken)
    {
        if (!Input.Page(limit, out var size)) return Input.Invalid("limit phải từ 1 đến 50.");
        if (after.HasValue)
        {
            var anchor = await query.SingleOrDefaultAsync(post => post.Id == after.Value, cancellationToken);
            if (anchor is null) return Input.Invalid("Cursor không tồn tại trong danh sách đang xem.");
            query = query.Where(post => post.CreatedAt < anchor.CreatedAt || (post.CreatedAt == anchor.CreatedAt && post.Id.CompareTo(anchor.Id) < 0));
        }
        var rows = await query.Include(post => post.Author).OrderByDescending(post => post.CreatedAt).ThenByDescending(post => post.Id)
            .Take(size + 1).ToListAsync(cancellationToken);
        return Results.Ok(new { items = rows.Take(size).Select(post => View(post, privateView)), next = rows.Count > size ? rows[size - 1].Id : (Guid?)null });
    }

    private static Dictionary<string, object?> View(Post post, bool privateView)
    {
        var result = new Dictionary<string, object?>
        {
            ["id"] = post.Id, ["title"] = post.Title, ["body"] = post.Body, ["productCode"] = post.ProductCode,
            ["status"] = post.Status, ["sourceType"] = post.SourceType, ["estimatedQuantityKg"] = post.EstimatedQuantityKg,
            ["createdAt"] = post.CreatedAt, ["revision"] = post.Revision, ["reviewedAt"] = post.ReviewedAt,
            ["branchId"] = post.BranchId, ["branchApprovalAtSubmission"] = post.BranchId.HasValue ? "Approved" : "LegacyUnrecorded",
            ["region"] = string.IsNullOrWhiteSpace(post.Region) ? post.Author.Region : post.Region,
            ["purpose"] = post.Purpose, ["availableOn"] = post.AvailableOn,
            ["priceMinVndPerKg"] = post.PriceMinVndPerKg, ["priceMaxVndPerKg"] = post.PriceMaxVndPerKg,
            ["author"] = new { id = post.AuthorId, displayName = post.Author.DisplayName, region = post.Author.Region },
            ["actualStockKg"] = null, ["canOrder"] = false
        };
        if (privateView) result["reviewReason"] = post.ReviewReason;
        return result;
    }

    private static async Task<IResult> Submit(CreatePostRequest request, HttpContext http, AppDbContext db,
        IHubContext<FruitHub> hub, ILoggerFactory loggerFactory, CancellationToken cancellationToken)
    {
        if (!Input.Safe(request.Title) || !Input.Safe(request.Body, true)) return Input.Invalid("Nội dung chứa ký tự điều khiển.");
        if (request.BranchId is null || request.BranchId == Guid.Empty) return Input.Invalid("Hãy chọn chi nhánh đã được duyệt trước khi gửi tin kinh doanh.");
        if (!await db.Products.AnyAsync(product => product.Code == request.ProductCode, cancellationToken)) return Input.Invalid("Nông sản không tồn tại.");
        if (request.PriceMinVndPerKg.HasValue != request.PriceMaxVndPerKg.HasValue ||
            (request.PriceMinVndPerKg.HasValue && (request.PriceMinVndPerKg <= 0 || request.PriceMaxVndPerKg < request.PriceMinVndPerKg ||
                request.PriceMaxVndPerKg > 1_000_000_000m || decimal.Round(request.PriceMinVndPerKg.Value, 2) != request.PriceMinVndPerKg ||
                decimal.Round(request.PriceMaxVndPerKg!.Value, 2) != request.PriceMaxVndPerKg)))
            return Input.Invalid("Giá cần đủ min/max, lớn hơn 0, max không nhỏ hơn min, tối đa 1 tỷ VND/kg và hai chữ số thập phân.");
        var today = DateOnly.FromDateTime(DateTime.UtcNow);
        if (request.AvailableOn is { } day && (day < today.AddDays(-1) || day > today.AddYears(2))) return Input.Invalid("Ngày dự kiến cần nằm trong khoảng hôm qua đến hai năm tới theo UTC.");
        await using var transaction = await db.Database.BeginTransactionAsync(cancellationToken);
        var userId = http.User.UserId();
        var author = await db.Users.FromSqlInterpolated($"SELECT * FROM \"AspNetUsers\" WHERE \"Id\"={userId} FOR SHARE").SingleAsync(cancellationToken);
        if (!author.IsActive || author.ApprovalStatus != ApprovalState.Approved || author.Role is not (AccountRole.Producer or AccountRole.Trader)) return Results.Forbid();
        var purpose = request.Purpose ?? (author.Role == AccountRole.Trader ? "Demand" : "Supply");
        if (purpose is not ("Supply" or "Demand") || (author.Role == AccountRole.Producer && purpose != "Supply")) return Input.Invalid("Producer chỉ gửi Supply; Trader có thể gửi Supply hoặc Demand.");
        var branch = await PublishingEndpoints.ValidateOwnedApprovedBranch(db, userId, request.BranchId, cancellationToken);
        if (branch is null) return Results.Problem(statusCode:409,title:"Chi nhánh chưa được duyệt hoặc không thuộc tài khoản. Vui lòng tải lại danh sách.");
        var region = branch.Region;
        var post = new Post { AuthorId = userId, Author = author, Title = Input.Text(request.Title), Body = Input.Text(request.Body),
            BranchId = branch.Id,
            ProductCode = request.ProductCode, EstimatedQuantityKg = request.EstimatedQuantityKg, Purpose = purpose, Region = region,
            AvailableOn = request.AvailableOn, PriceMinVndPerKg = request.PriceMinVndPerKg, PriceMaxVndPerKg = request.PriceMaxVndPerKg };
        db.Posts.Add(post); db.AuditEntries.Add(SessionTokens.Audit(userId, userId, "ForecastPostSubmitted", post.Id.ToString()));
        await db.SaveChangesAsync(cancellationToken); await transaction.CommitAsync(cancellationToken);
        await Notify(post, hub, loggerFactory, false);
        return Results.Created($"/api/v1/posts/{post.Id}", View(post, true));
    }

    private static async Task<IResult> Review(Guid id, PostReviewRequest request, HttpContext http, AppDbContext db,
        IHubContext<FruitHub> hub, ILoggerFactory loggerFactory, CancellationToken cancellationToken)
    {
        if (request.Status is not ("Published" or "Rejected" or "Paused") || !Input.Safe(request.Reason)) return Input.Invalid("Kết quả hoặc lý do kiểm duyệt không hợp lệ.");
        await using var transaction = await db.Database.BeginTransactionAsync(cancellationToken);
        var post = await db.Posts.FromSqlInterpolated($"SELECT * FROM \"Posts\" WHERE \"Id\"={id} FOR UPDATE").SingleOrDefaultAsync(cancellationToken);
        if (post is null) return Results.NotFound();
        var allowed = (post.Status, request.Status) is ("AwaitingReview", "Published") or ("AwaitingReview", "Rejected") or ("Published", "Paused") or ("Paused", "Published");
        if (post.Revision != request.ExpectedRevision || !allowed) return Results.Conflict(new { message = "Trạng thái hoặc phiên bản tin đã thay đổi; hãy tải lại." });
        var authorId = post.AuthorId;
        post.Author = await db.Users.FromSqlInterpolated($"SELECT * FROM \"AspNetUsers\" WHERE \"Id\"={authorId} FOR SHARE").SingleAsync(cancellationToken);
        if (request.Status == "Published" && (!post.Author.IsActive || post.Author.ApprovalStatus != ApprovalState.Approved))
            return Results.Conflict(new { message = "Tác giả cần đang hoạt động và được duyệt trước khi công bố tin." });
        var wasVisible = Visible(post);
        post.Status = request.Status; post.Revision++; post.ReviewReason = Input.Text(request.Reason);
        post.ReviewedAt = DateTimeOffset.UtcNow; post.ReviewedById = http.User.UserId();
        db.AuditEntries.Add(SessionTokens.Audit(http.User.UserId(), authorId, "PostReviewed", $"{post.Id}: {post.Status}: {post.ReviewReason}"));
        db.InteractionHistories.Add(new InteractionHistory { UserId = authorId, Kind = "PostReviewed", Title = "Kết quả kiểm duyệt tin dự kiến", Body = $"{post.Title}: {post.Status}. {post.ReviewReason}" });
        await db.SaveChangesAsync(cancellationToken); await transaction.CommitAsync(cancellationToken);
        await Notify(post, hub, loggerFactory, wasVisible != Visible(post));
        return Results.Ok(View(post, true));
    }

    private static async Task<IResult> Contact(Guid id, ContactPostRequest request, HttpContext http, AppDbContext db,
        IHubContext<FruitHub> hub, ILoggerFactory loggerFactory, CancellationToken cancellationToken)
    {
        if (http.User.IsInRole("Admin")) return Results.Forbid();
        var userId = http.User.UserId();
        await using var transaction = await db.Database.BeginTransactionAsync(cancellationToken);
        var lockKey = $"post-contact:{id:N}:{userId:N}";
        await db.Database.ExecuteSqlInterpolatedAsync($"SELECT pg_advisory_xact_lock(hashtextextended({lockKey},0))", cancellationToken);
        var post = await db.Posts.FromSqlInterpolated($"SELECT * FROM \"Posts\" WHERE \"Id\"={id} FOR SHARE").SingleOrDefaultAsync(cancellationToken);
        if (post is null || post.Status != "Published") return Results.NotFound();
        var ownerId = post.AuthorId;
        var users = await db.Users.FromSqlInterpolated($"SELECT * FROM \"AspNetUsers\" WHERE \"Id\"={ownerId} OR \"Id\"={userId} FOR SHARE").ToListAsync(cancellationToken);
        var author = users.Single(user => user.Id == ownerId); var initiator = users.Single(user => user.Id == userId);
        if (!author.IsActive || author.ApprovalStatus != ApprovalState.Approved) return Results.NotFound();
        if (!initiator.IsActive || initiator.ApprovalStatus != ApprovalState.Approved || initiator.Role == AccountRole.Admin) return Results.Forbid();
        if (ownerId == userId) return Results.Conflict(new { message = "Không tạo hội thoại với tin của chính mình." });
        var thread = await db.Conversations.SingleOrDefaultAsync(conversation => conversation.PostId == id && conversation.InitiatorId == userId && conversation.Kind == "Direct", cancellationToken);
        if (thread is not null)
        {
            var members = await db.Participants.Where(member => member.ConversationId == thread.Id).Select(member => member.UserId).ToListAsync(cancellationToken);
            if (members.Count != 2 || !members.Contains(ownerId) || !members.Contains(userId)) return Results.Conflict(new { message = "Thành viên hội thoại không còn phù hợp." });
            return Results.Ok(ThreadView(thread));
        }
        thread = await db.Conversations.Where(conversation => conversation.PostId == id && conversation.Kind == "Direct" && conversation.InitiatorId == null &&
            db.Participants.Count(member => member.ConversationId == conversation.Id) == 2 &&
            db.Participants.Any(member => member.ConversationId == conversation.Id && member.UserId == ownerId) &&
            db.Participants.Any(member => member.ConversationId == conversation.Id && member.UserId == userId)).OrderBy(conversation => conversation.Id).FirstOrDefaultAsync(cancellationToken);
        if (thread is not null)
        {
            thread.InitiatorId = userId; await db.SaveChangesAsync(cancellationToken); await transaction.CommitAsync(cancellationToken);
            return Results.Ok(ThreadView(thread));
        }
        thread = new Conversation { PostId = id, InitiatorId = userId, OwnerId = ownerId, Kind = "Direct", Title = "Trao đổi · " + post.Title,
            Region = string.IsNullOrWhiteSpace(post.Region) ? author.Region : post.Region, ProductCode = post.ProductCode };
        db.Conversations.Add(thread);
        db.Participants.AddRange(new Participant { ConversationId = thread.Id, UserId = ownerId }, new Participant { ConversationId = thread.Id, UserId = userId });
        foreach (var recipient in new[] { ownerId, userId }) db.InteractionHistories.Add(new InteractionHistory { UserId = recipient,
            Kind = "ConversationCreated", Title = "Hội thoại từ tin dự kiến", Body = $"Đã mở trao đổi riêng về tin {post.Title}; chưa tạo đơn hàng hoặc cam kết giao dịch." });
        await db.SaveChangesAsync(cancellationToken); await transaction.CommitAsync(cancellationToken);
        try { await hub.Clients.Groups(new[] { $"user:{ownerId}", $"user:{userId}" }).SendAsync("ConversationCreated", new { eventId = Guid.NewGuid(), id = thread.Id, postId = id }); }
        catch (Exception) { loggerFactory.CreateLogger("PostWorkflow").LogWarning("Conversation {ConversationId} notification was not delivered.", thread.Id); }
        return Results.Created($"/api/v1/conversations/{thread.Id}/messages", ThreadView(thread));
    }

    private static object ThreadView(Conversation conversation) => new { id = conversation.Id, title = conversation.Title, postId = conversation.PostId };
    private static async Task Notify(Post post, IHubContext<FruitHub> hub, ILoggerFactory loggerFactory, bool visibilityChanged)
    {
        var payload = new { eventId = Guid.NewGuid(), postId = post.Id, status = post.Status, revision = post.Revision };
        try
        {
            await hub.Clients.Groups(new[] { $"user:{post.AuthorId}", "role:Admin" }).SendAsync("PostChanged", payload);
            if (visibilityChanged) await hub.Clients.Group("approved").SendAsync("PublishedPostChanged", payload);
        }
        catch (Exception) { loggerFactory.CreateLogger("PostWorkflow").LogWarning("Post {PostId} notification was not delivered.", post.Id); }
    }
}

