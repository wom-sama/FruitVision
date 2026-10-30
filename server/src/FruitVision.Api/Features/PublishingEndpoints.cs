using FruitVision.Api.Auth;
using FruitVision.Api.Contracts;
using FruitVision.Api.Data;
using FruitVision.Api.Infrastructure;
using FruitVision.Api.Realtime;
using Microsoft.AspNetCore.SignalR;
using Microsoft.EntityFrameworkCore;

namespace FruitVision.Api.Features;

public static class PublishingEndpoints
{
    private static readonly string[] ArticleStates = ["AwaitingReview", "Published", "Rejected", "Paused"];
    private static readonly string[] BranchStates = ["Pending", "Approved", "Rejected", "NeedsInformation"];

    public static void MapPublishing(this WebApplication app)
    {
        app.MapGet("/api/v1/articles", async (string? lane, int? limit, Guid? after, AppDbContext db, CancellationToken ct) =>
            ValidLane(lane) ? await ArticlePage(FilterLane(PublicArticles(db), lane), limit, after, false, ct) : Input.Invalid("lane phải là Community hoặc Professional."));
        app.MapGet("/api/v1/articles/mine", async (string? lane, int? limit, Guid? after, HttpContext http, AppDbContext db, CancellationToken ct) =>
            ValidLane(lane) ? await ArticlePage(FilterLane(db.Set<CommunityArticle>().AsNoTracking().Where(a => a.AuthorId == http.User.UserId()), lane), limit, after, true, ct) : Input.Invalid("lane phải là Community hoặc Professional.")).RequireAuthorization();
        app.MapGet("/api/v1/articles/{id:guid}", async (Guid id, HttpContext http, AppDbContext db, CancellationToken ct) =>
        {
            var article = await db.Set<CommunityArticle>().AsNoTracking().Include(a => a.Author).Include(a => a.Branch).Include(a => a.Image).SingleOrDefaultAsync(a => a.Id == id, ct);
            if (article is null) return Results.NotFound();
            var privateView = Private(http, article.AuthorId);
            return privateView || ArticleVisible(article) ? Results.Ok(ArticleView(article, privateView)) : Results.NotFound();
        });
        app.MapPost("/api/v1/articles", SubmitArticle).RequireAuthorization("Approved")
            .RequireAuthorization(policy => policy.RequireRole("Consumer", "Producer", "Trader")).AddEndpointFilter<InputFilter>();
        app.MapPut("/api/v1/articles/{id:guid}", ReviseArticle).RequireAuthorization("Approved")
            .RequireAuthorization(policy => policy.RequireRole("Consumer", "Producer", "Trader")).AddEndpointFilter<InputFilter>();
        app.MapPost("/api/v1/articles/{id:guid}/withdraw", WithdrawArticle).RequireAuthorization("Approved")
            .RequireAuthorization(policy => policy.RequireRole("Consumer", "Producer", "Trader")).AddEndpointFilter<InputFilter>();
        app.MapGet("/api/v1/admin/articles", async (string? status, string? lane, int? limit, Guid? after, AppDbContext db, CancellationToken ct) =>
        {
            if (status is not null && !ArticleStates.Contains(status)) return Input.Invalid("Trạng thái bài viết không hợp lệ.");
            if (!ValidLane(lane)) return Input.Invalid("lane phải là Community hoặc Professional.");
            var query = FilterLane(db.Set<CommunityArticle>().AsNoTracking(), lane);
            if (status is not null) query = query.Where(a => a.Status == status);
            return await ArticlePage(query, limit, after, true, ct);
        }).RequireAuthorization("Admin");
        app.MapPost("/api/v1/admin/articles/{id:guid}/review", ReviewArticle).RequireAuthorization("Admin").AddEndpointFilter<InputFilter>();

        app.MapGet("/api/v1/branches/mine", async (int? limit, Guid? after, HttpContext http, AppDbContext db, CancellationToken ct) =>
            await BranchPage(db.Set<SellerBranch>().AsNoTracking().Where(b => b.OwnerId == http.User.UserId()), limit, after, ct)).RequireAuthorization("Seller");
        app.MapGet("/api/v1/branches/{id:guid}", async (Guid id, HttpContext http, AppDbContext db, CancellationToken ct) =>
        {
            var branch = await db.Set<SellerBranch>().AsNoTracking().Include(b => b.Owner).SingleOrDefaultAsync(b => b.Id == id, ct);
            if (branch is null) return Results.NotFound();
            var privateView = Private(http, branch.OwnerId);
            return privateView || BranchVisible(branch) ? Results.Ok(BranchView(branch, privateView)) : Results.NotFound();
        });
        app.MapPost("/api/v1/branches", SubmitBranch).RequireAuthorization("Seller").AddEndpointFilter<InputFilter>();
        app.MapPut("/api/v1/branches/{id:guid}", ReviseBranch).RequireAuthorization("Seller").AddEndpointFilter<InputFilter>();
        app.MapGet("/api/v1/admin/branches", async (string? status, int? limit, Guid? after, AppDbContext db, CancellationToken ct) =>
        {
            if (status is not null && !BranchStates.Contains(status)) return Input.Invalid("Trạng thái chi nhánh không hợp lệ.");
            var query = db.Set<SellerBranch>().AsNoTracking().AsQueryable();
            if (status is not null) query = query.Where(b => b.Status == status);
            return await BranchPage(query, limit, after, ct);
        }).RequireAuthorization("Admin");
        app.MapPost("/api/v1/admin/branches/{id:guid}/review", ReviewBranch).RequireAuthorization("Admin").AddEndpointFilter<InputFilter>();
    }

    // Use inside the caller's business-post transaction so FOR SHARE retains branch approval until commit.
    public static async Task<SellerBranch?> ValidateOwnedApprovedBranch(AppDbContext db, Guid userId,
        Guid? branchId, CancellationToken cancellationToken = default)
    {
        if (!await db.Users.AsNoTracking().AnyAsync(u => u.Id == userId && u.IsActive && u.ApprovalStatus == ApprovalState.Approved &&
                (u.Role == AccountRole.Producer || u.Role == AccountRole.Trader), cancellationToken)) return null;
        if (branchId.HasValue)
            return await db.Set<SellerBranch>().FromSqlInterpolated($"SELECT * FROM \"SellerBranches\" WHERE \"Id\"={branchId.Value} AND \"OwnerId\"={userId} AND \"Status\"='Approved' FOR SHARE")
                .SingleOrDefaultAsync(cancellationToken);
        var choices = await db.Set<SellerBranch>().FromSqlInterpolated($"SELECT * FROM \"SellerBranches\" WHERE \"OwnerId\"={userId} AND \"Status\"='Approved' ORDER BY \"Id\" LIMIT 2 FOR SHARE")
            .ToListAsync(cancellationToken);
        return choices.Count == 1 ? choices[0] : null;
    }

    private static bool Private(HttpContext http, Guid owner) => http.User.Identity?.IsAuthenticated == true &&
        (http.User.UserId() == owner || (http.User.IsInRole("Admin") && http.User.HasClaim("approval", "Approved")));
    private static bool Eligible(AppUser user) => user.IsActive && user.ApprovalStatus == ApprovalState.Approved;
    private static bool Seller(AppUser user) => Eligible(user) && user.Role is AccountRole.Producer or AccountRole.Trader;
    private static bool ValidLane(string? lane) => lane is null or "Community" or "Professional";
    private static IQueryable<CommunityArticle> FilterLane(IQueryable<CommunityArticle> query, string? lane) => lane is null ? query : query.Where(a => a.AudienceLane == lane);
    private static IQueryable<CommunityArticle> PublicArticles(AppDbContext db) => db.Set<CommunityArticle>().AsNoTracking().Where(a =>
        a.Status == "Published" && a.Author.IsActive && a.Author.ApprovalStatus == ApprovalState.Approved &&
        (a.AudienceLane == "Community" || (a.Branch != null && a.Branch.Status == "Approved" && a.Branch.OwnerId == a.AuthorId &&
            (a.Author.Role == AccountRole.Producer || a.Author.Role == AccountRole.Trader))));
    internal static bool IsArticlePublic(CommunityArticle article) => article.Status == "Published" && Eligible(article.Author) &&
        (article.AudienceLane == "Community" || (Seller(article.Author) && article.Branch is { Status: "Approved" } && article.Branch.OwnerId == article.AuthorId));
    private static bool ArticleVisible(CommunityArticle article) => IsArticlePublic(article);
    private static async Task LoadArticleRelations(AppDbContext db, CommunityArticle article, CancellationToken ct)
    {
        article.Branch = article.BranchId.HasValue ? await db.Set<SellerBranch>().SingleOrDefaultAsync(b => b.Id == article.BranchId.Value, ct) : null;
        article.Image = article.ImageId.HasValue ? await db.Set<NormalImage>().SingleOrDefaultAsync(i => i.Id == article.ImageId.Value, ct) : null;
    }
    private static bool BranchVisible(SellerBranch branch) => branch.Status == "Approved" && Seller(branch.Owner);
    private static bool ArticleText(string title, string body) => Input.Safe(title) && Input.Safe(body, true) &&
        Input.Text(title).Length is >= 5 and <= 160 && Input.Text(body).Length is >= 10 and <= 5000;
    private static bool BranchText(string name, string street, string phone) => Input.Safe(name) && Input.Safe(street) && Input.Safe(phone) &&
        Input.Text(name).Length is >= 2 and <= 160 && Input.Text(street).Length is >= 5 and <= 240 &&
        Input.Text(phone).Length is >= 7 and <= 30 && phone.All(c => char.IsAsciiDigit(c) || c is '+' or ' ' or '(' or ')' or '-' or '.') &&
        phone.Count(char.IsAsciiDigit) is >= 7 and <= 15;
    private static bool LocationFits(ValidatedLocation location) => new[] { location.CountryName, location.ProvinceName, location.Region }
        .All(label => label.Length is > 0 and <= 120 && Input.Safe(label));
    private static Task<AppUser> LockedUser(AppDbContext db, Guid id, CancellationToken ct) =>
        db.Users.FromSqlInterpolated($"SELECT * FROM \"AspNetUsers\" WHERE \"Id\"={id} FOR SHARE").SingleAsync(ct);

    private static async Task<IResult> SubmitArticle(CreateArticleRequest request, HttpContext http, AppDbContext db,
        IHubContext<FruitHub> hub, ILoggerFactory logs, CancellationToken ct)
    {
        if (!ArticleText(request.Title, request.Body)) return Input.Invalid("Bài viết cần tiêu đề 5–160, nội dung 10–5000 ký tự hợp lệ.");
        await using var transaction = await db.Database.BeginTransactionAsync(ct);
        var owner = await LockedUser(db, http.User.UserId(), ct);
        if (!Eligible(owner) || owner.Role == AccountRole.Admin) return Results.Forbid();
        if (owner.Role == AccountRole.Consumer && request.BranchId.HasValue) return Input.Invalid("Bài cộng đồng không gắn chi nhánh.");
        SellerBranch? branch = null;
        if (Seller(owner))
        {
            if (!request.BranchId.HasValue) return Input.Invalid("Bài chuyên môn cần chọn chi nhánh đã được duyệt.");
            branch = await ValidateOwnedApprovedBranch(db, owner.Id, request.BranchId, ct);
            if (branch is null) return Results.Conflict(new { message = "Chi nhánh cần thuộc tác giả và đang được duyệt." });
        }
        NormalImage? image;
        try { image = await NormalMediaEndpoints.ClaimArticleImage(db, owner.Id, request.ImageId, null, ct); }
        catch (NormalImageException) { return Input.Invalid("Ảnh không thuộc tài khoản hoặc đã được dùng cho bài khác."); }
        var article = new CommunityArticle { AuthorId = owner.Id, Author = owner, Title = Input.Text(request.Title), Body = Input.Text(request.Body),
            AudienceLane = Seller(owner) ? "Professional" : "Community", BranchId = branch?.Id, Branch = branch, ImageId = image?.Id, Image = image };
        db.Add(article); db.AuditEntries.Add(SessionTokens.Audit(owner.Id, owner.Id, "ArticleSubmitted", article.Id.ToString()));
        await db.SaveChangesAsync(ct); await transaction.CommitAsync(ct);
        await Notify(hub, logs, "Article", article.Id, owner.Id, article.Status, article.Revision, false);
        return Results.Created($"/api/v1/articles/{article.Id}", ArticleView(article, true));
    }
    private static async Task<IResult> ReviseArticle(Guid id, UpdateArticleRequest request, HttpContext http, AppDbContext db,
        IHubContext<FruitHub> hub, ILoggerFactory logs, CancellationToken ct)
    {
        if (!ArticleText(request.Title, request.Body)) return Input.Invalid("Nội dung bài viết không hợp lệ.");
        var uid = http.User.UserId(); await using var transaction = await db.Database.BeginTransactionAsync(ct);
        var article = await db.Set<CommunityArticle>().FromSqlInterpolated($"SELECT * FROM \"CommunityArticles\" WHERE \"Id\"={id} AND \"AuthorId\"={uid} FOR UPDATE").SingleOrDefaultAsync(ct);
        if (article is null) return Results.NotFound();
        article.Author = await LockedUser(db, uid, ct);
        if (!Eligible(article.Author) || article.Author.Role == AccountRole.Admin || (article.AudienceLane == "Professional" && !Seller(article.Author))) return Results.Forbid();
        if (article.Revision != request.ExpectedRevision) return Results.Conflict(new { message = "Bài viết đã thay đổi; hãy tải lại phiên bản mới." });
        await LoadArticleRelations(db, article, ct);
        var visibilityChanged = ArticleVisible(article);
        if (article.AudienceLane == "Community" && request.BranchId.HasValue) return Input.Invalid("Bài cộng đồng không gắn chi nhánh.");
        if (article.AudienceLane == "Professional")
        {
            var branch = await ValidateOwnedApprovedBranch(db, uid, request.BranchId ?? article.BranchId, ct);
            if (branch is null) return Results.Conflict(new { message = "Chi nhánh cần thuộc tác giả và đang được duyệt." });
            article.Branch = branch; article.BranchId = branch.Id;
        }
        try { article.Image = await NormalMediaEndpoints.ClaimArticleImage(db, uid, request.ImageId, article.ImageId, ct); article.ImageId = article.Image?.Id; }
        catch (NormalImageException) { return Input.Invalid("Ảnh không thuộc tài khoản hoặc đã được dùng cho bài khác."); }
        article.Title = Input.Text(request.Title); article.Body = Input.Text(request.Body); article.Status = "AwaitingReview";
        article.Revision++; article.UpdatedAt = DateTimeOffset.UtcNow; article.ReviewReason = null; article.ReviewedAt = null; article.ReviewedById = null;
        db.AuditEntries.Add(SessionTokens.Audit(uid, uid, "ArticleRevised", id.ToString()));
        await db.SaveChangesAsync(ct); await transaction.CommitAsync(ct);
        await Notify(hub, logs, "Article", id, uid, article.Status, article.Revision, visibilityChanged);
        return Results.Ok(ArticleView(article, true));
    }
    private static async Task<IResult> WithdrawArticle(Guid id, PublishingRevisionRequest request, HttpContext http, AppDbContext db,
        IHubContext<FruitHub> hub, ILoggerFactory logs, CancellationToken ct)
    {
        var uid = http.User.UserId(); await using var transaction = await db.Database.BeginTransactionAsync(ct);
        var article = await db.Set<CommunityArticle>().FromSqlInterpolated($"SELECT * FROM \"CommunityArticles\" WHERE \"Id\"={id} AND \"AuthorId\"={uid} FOR UPDATE").SingleOrDefaultAsync(ct);
        if (article is null) return Results.NotFound();
        article.Author = await LockedUser(db, uid, ct);
        if (!Eligible(article.Author) || article.Author.Role == AccountRole.Admin) return Results.Forbid();
        await LoadArticleRelations(db, article, ct);
        if (article.Revision != request.ExpectedRevision || article.Status != "Published") return Results.Conflict(new { message = "Chỉ rút bài đã công bố ở phiên bản hiện tại." });
        article.Status = "Paused"; article.Revision++; article.UpdatedAt = DateTimeOffset.UtcNow;
        db.AuditEntries.Add(SessionTokens.Audit(uid, uid, "ArticleWithdrawn", id.ToString()));
        await db.SaveChangesAsync(ct); await transaction.CommitAsync(ct);
        await Notify(hub, logs, "Article", id, uid, article.Status, article.Revision, true);
        return Results.Ok(ArticleView(article, true));
    }
    private static async Task<IResult> ReviewArticle(Guid id, PublishingReviewRequest request, HttpContext http, AppDbContext db,
        IHubContext<FruitHub> hub, ILoggerFactory logs, CancellationToken ct)
    {
        if (request.Status is not ("Published" or "Rejected" or "Paused") || !Input.Safe(request.Reason) || Input.Text(request.Reason).Length < 3)
            return Input.Invalid("Kết quả hoặc lý do xét duyệt bài viết không hợp lệ.");
        await using var transaction = await db.Database.BeginTransactionAsync(ct);
        var article = await db.Set<CommunityArticle>().FromSqlInterpolated($"SELECT * FROM \"CommunityArticles\" WHERE \"Id\"={id} FOR UPDATE").SingleOrDefaultAsync(ct);
        if (article is null) return Results.NotFound();
        var allowed = (article.Status, request.Status) is ("AwaitingReview", "Published") or ("AwaitingReview", "Rejected") or ("Published", "Paused") or ("Paused", "Published");
        if (!allowed || article.Revision != request.ExpectedRevision) return Results.Conflict(new { message = "Trạng thái hoặc phiên bản bài viết đã thay đổi." });
        article.Author = await LockedUser(db, article.AuthorId, ct);
        await LoadArticleRelations(db, article, ct);
        if (request.Status == "Published" && !Eligible(article.Author)) return Results.Conflict(new { message = "Tác giả cần đang hoạt động và được duyệt." });
        if (request.Status == "Published" && article.AudienceLane == "Professional" &&
            (!Seller(article.Author) || !article.BranchId.HasValue || await ValidateOwnedApprovedBranch(db, article.AuthorId, article.BranchId, ct) is null))
            return Results.Conflict(new { message = "Bài chuyên môn cần tác giả Producer/Trader và chi nhánh đang được duyệt." });
        var wasVisible = ArticleVisible(article); article.Status = request.Status; article.Revision++;
        article.ReviewReason = Input.Text(request.Reason); article.ReviewedAt = article.UpdatedAt = DateTimeOffset.UtcNow; article.ReviewedById = http.User.UserId();
        db.AuditEntries.Add(SessionTokens.Audit(http.User.UserId(), article.AuthorId, "ArticleReviewed", $"{id}: {article.Status}: {article.ReviewReason}"));
        db.InteractionHistories.Add(new InteractionHistory { UserId = article.AuthorId, Kind = "ArticleReviewed", Title = "Kết quả xét duyệt bài viết", Body = $"{article.Title}: {article.Status}. {article.ReviewReason}" });
        await db.SaveChangesAsync(ct); await transaction.CommitAsync(ct);
        await Notify(hub, logs, "Article", id, article.AuthorId, article.Status, article.Revision, wasVisible != ArticleVisible(article));
        return Results.Ok(ArticleView(article, true));
    }

    private static async Task<IResult> SubmitBranch(CreateBranchRequest request, HttpContext http, AppDbContext db,
        LocationDirectory directory, IHubContext<FruitHub> hub, ILoggerFactory logs, CancellationToken ct)
    {
        if (!BranchText(request.Name, request.Street, request.Phone)) return Input.Invalid("Tên, địa chỉ hoặc số điện thoại chi nhánh không hợp lệ.");
        var location = await directory.ValidateAsync(request.CountryCode, request.ProvinceCode, ct);
        if (!LocationFits(location)) return Input.Invalid("Nhãn địa điểm vượt giới hạn 120 ký tự; không tự cắt mã hoặc nhãn.");
        await using var transaction = await db.Database.BeginTransactionAsync(ct);
        var owner = await LockedUser(db, http.User.UserId(), ct);
        if (!Seller(owner)) return Results.Forbid();
        var branch = new SellerBranch { OwnerId = owner.Id, Owner = owner };
        SetBranch(branch, request.Name, request.Street, request.Phone, location);
        db.Add(branch); db.AuditEntries.Add(SessionTokens.Audit(owner.Id, owner.Id, "BranchSubmitted", branch.Id.ToString()));
        await db.SaveChangesAsync(ct); await transaction.CommitAsync(ct);
        await Notify(hub, logs, "Branch", branch.Id, owner.Id, branch.Status, branch.Revision, false);
        return Results.Created($"/api/v1/branches/{branch.Id}", BranchView(branch, true));
    }
    private static async Task<IResult> ReviseBranch(Guid id, UpdateBranchRequest request, HttpContext http, AppDbContext db,
        LocationDirectory directory, IHubContext<FruitHub> hub, ILoggerFactory logs, CancellationToken ct)
    {
        var uid = http.User.UserId();
        if (!await db.Set<SellerBranch>().AsNoTracking().AnyAsync(b => b.Id == id && b.OwnerId == uid, ct)) return Results.NotFound();
        if (!BranchText(request.Name, request.Street, request.Phone)) return Input.Invalid("Thông tin chi nhánh không hợp lệ.");
        var location = await directory.ValidateAsync(request.CountryCode, request.ProvinceCode, ct);
        if (!LocationFits(location)) return Input.Invalid("Nhãn địa điểm vượt giới hạn 120 ký tự; không tự cắt mã hoặc nhãn.");
        await using var transaction = await db.Database.BeginTransactionAsync(ct);
        var branch = await db.Set<SellerBranch>().FromSqlInterpolated($"SELECT * FROM \"SellerBranches\" WHERE \"Id\"={id} AND \"OwnerId\"={uid} FOR UPDATE").SingleOrDefaultAsync(ct);
        if (branch is null) return Results.NotFound();
        branch.Owner = await LockedUser(db, uid, ct);
        if (!Seller(branch.Owner)) return Results.Forbid();
        if (branch.Revision != request.ExpectedRevision) return Results.Conflict(new { message = "Chi nhánh đã thay đổi; hãy tải lại phiên bản mới." });
        var visibilityChanged = BranchVisible(branch);
        SetBranch(branch, request.Name, request.Street, request.Phone, location);
        branch.Status = "Pending"; branch.Revision++; branch.UpdatedAt = DateTimeOffset.UtcNow;
        branch.ReviewReason = null; branch.ReviewedAt = null; branch.ReviewedById = null;
        db.AuditEntries.Add(SessionTokens.Audit(uid, uid, "BranchRevised", id.ToString()));
        await db.SaveChangesAsync(ct); await transaction.CommitAsync(ct);
        await Notify(hub, logs, "Branch", id, uid, branch.Status, branch.Revision, visibilityChanged);
        return Results.Ok(BranchView(branch, true));
    }
    private static async Task<IResult> ReviewBranch(Guid id, PublishingReviewRequest request, HttpContext http, AppDbContext db,
        IHubContext<FruitHub> hub, ILoggerFactory logs, CancellationToken ct)
    {
        if (request.Status is not ("Approved" or "Rejected" or "NeedsInformation") || !Input.Safe(request.Reason) || Input.Text(request.Reason).Length < 3)
            return Input.Invalid("Kết quả hoặc lý do xét duyệt chi nhánh không hợp lệ.");
        await using var transaction = await db.Database.BeginTransactionAsync(ct);
        var branch = await db.Set<SellerBranch>().FromSqlInterpolated($"SELECT * FROM \"SellerBranches\" WHERE \"Id\"={id} FOR UPDATE").SingleOrDefaultAsync(ct);
        if (branch is null) return Results.NotFound();
        var allowed = branch.Status == "Pending" || (branch.Status == "Approved" && request.Status is "Rejected" or "NeedsInformation");
        if (!allowed || branch.Revision != request.ExpectedRevision) return Results.Conflict(new { message = "Trạng thái hoặc phiên bản chi nhánh đã thay đổi; hồ sơ cần chỉnh sửa/gửi lại nếu bị trả về." });
        branch.Owner = await LockedUser(db, branch.OwnerId, ct);
        if (request.Status == "Approved" && !Seller(branch.Owner)) return Results.Conflict(new { message = "Chủ chi nhánh cần là Producer/Trader đang hoạt động, đã được duyệt." });
        var wasVisible = BranchVisible(branch); branch.Status = request.Status; branch.Revision++;
        branch.ReviewReason = Input.Text(request.Reason); branch.ReviewedAt = branch.UpdatedAt = DateTimeOffset.UtcNow; branch.ReviewedById = http.User.UserId();
        db.AuditEntries.Add(SessionTokens.Audit(http.User.UserId(), branch.OwnerId, "BranchReviewed", $"{id}: {branch.Status}: {branch.ReviewReason}"));
        db.InteractionHistories.Add(new InteractionHistory { UserId = branch.OwnerId, Kind = "BranchReviewed", Title = "Kết quả xét duyệt chi nhánh", Body = $"{branch.Name}: {branch.Status}. {branch.ReviewReason}" });
        await db.SaveChangesAsync(ct); await transaction.CommitAsync(ct);
        await Notify(hub, logs, "Branch", id, branch.OwnerId, branch.Status, branch.Revision, wasVisible != BranchVisible(branch));
        return Results.Ok(BranchView(branch, true));
    }
    private static void SetBranch(SellerBranch branch, string name, string street, string phone, ValidatedLocation location)
    {
        branch.Name = Input.Text(name); branch.Street = Input.Text(street); branch.Phone = Input.Text(phone);
        branch.CountryCode = location.CountryCode; branch.ProvinceCode = location.ProvinceCode;
        branch.CountryName = location.CountryName; branch.ProvinceName = location.ProvinceName; branch.Region = location.Region;
    }

    private static async Task<IResult> ArticlePage(IQueryable<CommunityArticle> query, int? limit, Guid? after, bool privateView, CancellationToken ct)
    {
        if (!Input.Page(limit, out var size)) return Input.Invalid("limit phải từ 1 đến 50.");
        if (after.HasValue)
        {
            var anchor = await query.SingleOrDefaultAsync(a => a.Id == after.Value, ct);
            if (anchor is null) return Input.Invalid("Cursor không tồn tại trong danh sách bài viết.");
            query = query.Where(a => a.CreatedAt < anchor.CreatedAt || (a.CreatedAt == anchor.CreatedAt && a.Id.CompareTo(anchor.Id) < 0));
        }
        var rows = await query.Include(a => a.Author).Include(a => a.Branch).Include(a => a.Image).OrderByDescending(a => a.CreatedAt).ThenByDescending(a => a.Id).Take(size + 1).ToListAsync(ct);
        return Results.Ok(new { items = rows.Take(size).Select(a => ArticleView(a, privateView)), next = rows.Count > size ? rows[size - 1].Id : (Guid?)null });
    }
    private static async Task<IResult> BranchPage(IQueryable<SellerBranch> query, int? limit, Guid? after, CancellationToken ct)
    {
        if (!Input.Page(limit, out var size)) return Input.Invalid("limit phải từ 1 đến 50.");
        if (after.HasValue)
        {
            var anchor = await query.SingleOrDefaultAsync(b => b.Id == after.Value, ct);
            if (anchor is null) return Input.Invalid("Cursor không tồn tại trong danh sách chi nhánh.");
            query = query.Where(b => b.CreatedAt < anchor.CreatedAt || (b.CreatedAt == anchor.CreatedAt && b.Id.CompareTo(anchor.Id) < 0));
        }
        var rows = await query.Include(b => b.Owner).OrderByDescending(b => b.CreatedAt).ThenByDescending(b => b.Id).Take(size + 1).ToListAsync(ct);
        return Results.Ok(new { items = rows.Take(size).Select(b => BranchView(b, true)), next = rows.Count > size ? rows[size - 1].Id : (Guid?)null });
    }
    private static Dictionary<string, object?> ArticleView(CommunityArticle article, bool privateView)
    {
        var result = new Dictionary<string, object?> { ["id"] = article.Id, ["title"] = article.Title, ["body"] = article.Body,
            ["audienceLane"] = article.AudienceLane, ["branchId"] = article.BranchId,
            ["image"] = article.Image is null ? null : NormalMediaEndpoints.ImageView(article.Image, $"/api/v1/articles/{article.Id}/image"),
            ["status"] = article.Status, ["revision"] = article.Revision, ["createdAt"] = article.CreatedAt,
            ["updatedAt"] = article.UpdatedAt, ["reviewedAt"] = article.ReviewedAt,
            ["author"] = new { id = article.AuthorId, displayName = article.Author.DisplayName, role = article.Author.Role.ToString() } };
        if (privateView) result["reviewReason"] = article.ReviewReason;
        return result;
    }
    private static Dictionary<string, object?> BranchView(SellerBranch branch, bool privateView)
    {
        var result = new Dictionary<string, object?> { ["id"] = branch.Id, ["name"] = branch.Name,
            ["countryCode"] = branch.CountryCode, ["provinceCode"] = branch.ProvinceCode, ["countryName"] = branch.CountryName,
            ["provinceName"] = branch.ProvinceName, ["region"] = branch.Region, ["status"] = branch.Status,
            ["owner"] = new { id = branch.OwnerId, displayName = branch.Owner.DisplayName, role = branch.Owner.Role.ToString() } };
        if (privateView)
        {
            result["street"] = branch.Street; result["phone"] = branch.Phone; result["revision"] = branch.Revision;
            result["createdAt"] = branch.CreatedAt; result["updatedAt"] = branch.UpdatedAt; result["reviewedAt"] = branch.ReviewedAt; result["reviewReason"] = branch.ReviewReason;
        }
        return result;
    }
    private static async Task Notify(IHubContext<FruitHub> hub, ILoggerFactory logs, string kind, Guid id,
        Guid owner, string status, int revision, bool visibilityChanged)
    {
        var payload = new { eventId = Guid.NewGuid(), id, status, revision };
        try
        {
            await hub.Clients.Groups(new[] { $"user:{owner}", "role:Admin" }).SendAsync(kind + "Changed", payload);
            if (visibilityChanged) await hub.Clients.Group("approved").SendAsync(kind == "Article" ? "PublishedArticleChanged" : "ApprovedBranchChanged", payload);
        }
        catch (Exception exception)
        { logs.CreateLogger("Publishing").LogWarning("Publishing {Kind} {RecordId} notification was not delivered ({FailureType}).", kind, id, exception.GetType().Name); }
    }
}
