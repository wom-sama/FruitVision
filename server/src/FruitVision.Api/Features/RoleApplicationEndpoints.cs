using System.Text.RegularExpressions;
using FruitVision.Api.Auth;
using FruitVision.Api.Contracts;
using FruitVision.Api.Data;
using FruitVision.Api.Infrastructure;
using FruitVision.Api.Realtime;
using Microsoft.AspNetCore.SignalR;
using Microsoft.EntityFrameworkCore;

namespace FruitVision.Api.Features;

public static class RoleApplicationEndpoints
{
    public static IServiceCollection AddRoleApplications(this IServiceCollection services, IConfiguration configuration)
    {
        services.Configure<RoleEvidenceOptions>(configuration.GetSection("RoleEvidence"));
        services.AddSingleton<RoleEvidenceStorage>();
        return services;
    }

    public static void MapRoleApplications(this WebApplication app)
    {
        var owner = app.MapGroup("/api/v1/role-applications").RequireAuthorization().AddEndpointFilter<InputFilter>().WithTags("Hồ sơ nâng vai trò");
        owner.MapGet("", (int? limit, Guid? after, HttpContext http, AppDbContext db, CancellationToken ct) => List(null, limit, after, http.User.UserId(), db, ct));
        owner.MapPost("", Create);
        owner.MapGet("/{id:guid}", Detail);
        owner.MapPut("/{id:guid}", Edit);
        owner.MapPost("/{id:guid}/submit", Submit);
        owner.MapPost("/{id:guid}/evidence", Upload);
        owner.MapDelete("/{id:guid}/evidence/{evidenceId:guid}", DeleteEvidence);
        owner.MapGet("/{id:guid}/evidence/{evidenceId:guid}", DownloadEvidence);
        var admin = app.MapGroup("/api/v1/admin/role-applications").RequireAuthorization("Admin").AddEndpointFilter<InputFilter>().WithTags("Xét duyệt nâng vai trò");
        admin.MapGet("", (string? status, int? limit, Guid? after, AppDbContext db, CancellationToken ct) => List(status, limit, after, null, db, ct));
        admin.MapGet("/{id:guid}", Detail);
        admin.MapGet("/{id:guid}/evidence/{evidenceId:guid}", DownloadEvidence);
        admin.MapPost("/{id:guid}/review", Review);
    }

    private static bool Eligible(AppUser? user) => user is { IsActive: true, EmailConfirmed: true, Role: AccountRole.Consumer, ApprovalStatus: ApprovalState.Approved } && !(user.LockoutEnd > DateTimeOffset.UtcNow);
    private static bool IsAdmin(HttpContext http) => http.User.IsInRole("Admin") && http.User.HasClaim("approval", "Approved");
    private static bool Editable(RoleApplication application) => application.Status is "Draft" or "NeedsInformation" or "Rejected";
    private static bool Active(RoleApplication application) => application.Status is "Draft" or "Submitted" or "NeedsInformation";
    private static string Category(RoleApplication application) => application.RequestedRole == AccountRole.Producer ? "ProductionEvidence" : "BusinessEvidence";
    private static Task<AppUser?> LockUser(AppDbContext db, Guid id, CancellationToken ct) => db.Users.FromSqlInterpolated($"SELECT * FROM \"AspNetUsers\" WHERE \"Id\"={id} FOR UPDATE").SingleOrDefaultAsync(ct);
    private static Task<RoleApplication?> LockApplication(AppDbContext db, Guid id, CancellationToken ct) => db.Set<RoleApplication>().FromSqlInterpolated($"SELECT * FROM \"RoleApplications\" WHERE \"Id\"={id} FOR UPDATE").SingleOrDefaultAsync(ct);
    private static void Changed(RoleApplication application) { application.Revision++; application.UpdatedAt = DateTimeOffset.UtcNow; }

    private static async Task<IResult> Create(CreateRoleApplicationRequest request, HttpContext http, AppDbContext db, CancellationToken ct)
    {
        await using var tx = await db.Database.BeginTransactionAsync(ct);
        var user = await LockUser(db, http.User.UserId(), ct);
        if (!Eligible(user)) return Input.Denied();
        if (request.RequestedRole is not ("Producer" or "Trader")) return Input.Invalid("Chỉ có thể đăng ký nâng vai trò Nhà vườn hoặc Thương lái.");
        if (await db.Set<RoleApplication>().AnyAsync(a => a.UserId == user!.Id && (a.Status == "Draft" || a.Status == "Submitted" || a.Status == "NeedsInformation"), ct)) return Results.Conflict();
        var application = new RoleApplication { UserId = user!.Id, RequestedRole = Enum.Parse<AccountRole>(request.RequestedRole) };
        db.Add(application);
        db.AuditEntries.Add(SessionTokens.Audit(user.Id, user.Id, "RoleApplicationCreated"));
        await db.SaveChangesAsync(ct);
        var view = await View(db, application, ct);
        await tx.CommitAsync(ct);
        await Notify(http, application);
        return Results.Created($"/api/v1/role-applications/{application.Id}", view);
    }

    private static async Task<IResult> List(string? status, int? limit, Guid? after, Guid? userId, AppDbContext db, CancellationToken ct)
    {
        if (!Input.Page(limit, out var size)) return Input.Invalid("limit phải từ 1 đến 50.");
        if (status is not null && status is not ("Draft" or "Submitted" or "NeedsInformation" or "Approved" or "Rejected")) return Input.Invalid("Trạng thái hồ sơ không hợp lệ.");
        var query = db.Set<RoleApplication>().AsNoTracking();
        var orderBySubmission = !userId.HasValue;
        if (userId.HasValue) query = query.Where(a => a.UserId == userId.Value);
        if (status is not null) query = query.Where(a => a.Status == status);
        if (after.HasValue)
        {
            var anchor = await query.SingleOrDefaultAsync(a => a.Id == after.Value, ct);
            if (anchor is null) return Input.Invalid("Mốc phân trang không hợp lệ.");
            if (orderBySubmission)
            {
                var time = anchor.SubmittedAt ?? anchor.CreatedAt;
                query = query.Where(a => (a.SubmittedAt ?? a.CreatedAt) < time || ((a.SubmittedAt ?? a.CreatedAt) == time && a.Id.CompareTo(anchor.Id) < 0));
            }
            else query = query.Where(a => a.CreatedAt < anchor.CreatedAt || (a.CreatedAt == anchor.CreatedAt && a.Id.CompareTo(anchor.Id) < 0));
        }
        var rows = await (orderBySubmission ? query.OrderByDescending(a => a.SubmittedAt ?? a.CreatedAt).ThenByDescending(a => a.Id) : query.OrderByDescending(a => a.CreatedAt).ThenByDescending(a => a.Id)).Take(size + 1).ToListAsync(ct);
        var ids = rows.Take(size).Select(a => a.Id).ToArray();
        var ownerIds = rows.Take(size).Select(a => a.UserId).Distinct().ToArray();
        var applicants = await db.Users.AsNoTracking().Where(u => ownerIds.Contains(u.Id)).ToDictionaryAsync(u => u.Id, ct);
        var evidence = await db.Set<RoleApplicationEvidence>().AsNoTracking().Where(e => ids.Contains(e.ApplicationId)).OrderBy(e => e.CreatedAt).ThenBy(e => e.Id).ToListAsync(ct);
        return Results.Ok(new { items = rows.Take(size).Select(a => ToView(a, evidence.Where(e => e.ApplicationId == a.Id), applicants[a.UserId])), next = rows.Count > size ? rows[size - 1].Id : (Guid?)null });
    }

    private static async Task<IResult> Detail(Guid id, HttpContext http, AppDbContext db, CancellationToken ct)
    {
        var application = await db.Set<RoleApplication>().AsNoTracking().SingleOrDefaultAsync(a => a.Id == id, ct);
        if (application is null || (application.UserId != http.User.UserId() && !IsAdmin(http))) return Results.NotFound();
        return Results.Ok(await View(db, application, ct));
    }

    private static async Task<IResult> Edit(Guid id, RoleApplicationProfileRequest request, HttpContext http, AppDbContext db, CancellationToken ct)
    {
        await using var tx = await db.Database.BeginTransactionAsync(ct);
        var user = await LockUser(db, http.User.UserId(), ct);
        if (!Eligible(user)) return Input.Denied();
        var application = await LockApplication(db, id, ct);
        if (application is null || application.UserId != user!.Id) return Results.NotFound();
        if (application.Revision != request.ExpectedRevision || !Editable(application)) return Results.Conflict();
        application.OrganisationName = Input.Text(request.OrganisationName);
        application.Address = Input.Text(request.Address);
        application.CountryCode = request.CountryCode;
        application.ProvinceCode = request.ProvinceCode;
        application.Phone = Input.Text(request.Phone);
        if (request.Products.Any(p => p is null)) return Input.Invalid("Sản phẩm không hợp lệ.");
        application.Products = request.Products.Select(Input.Text).ToArray();
        application.CultivatedAreaHa = request.CultivatedAreaHa;
        application.TaxCode = string.IsNullOrWhiteSpace(request.TaxCode) ? null : Input.Text(request.TaxCode);
        application.BusinessRegistrationNumber = string.IsNullOrWhiteSpace(request.BusinessRegistrationNumber) ? null : Input.Text(request.BusinessRegistrationNumber);
        var error = await ProfileError(application, db, http.RequestServices, ct);
        if (error is not null) return Input.Invalid(error);
        Changed(application);
        await db.SaveChangesAsync(ct);
        var view = await View(db, application, ct);
        await tx.CommitAsync(ct);
        await Notify(http, application);
        return Results.Ok(view);
    }

    private static async Task<string?> ProfileError(RoleApplication application, AppDbContext db, IServiceProvider services, CancellationToken ct)
    {
        if (application.OrganisationName.Length is < 2 or > 160 || !Input.Safe(application.OrganisationName) || application.Address.Length is < 5 or > 300 || !Input.Safe(application.Address) ||
            application.Phone.Length is < 8 or > 24 || !Regex.IsMatch(application.Phone, "^\\+?[0-9][0-9 -]*[0-9]$", RegexOptions.CultureInvariant, TimeSpan.FromMilliseconds(100))) return "Tên đơn vị, địa chỉ hoặc số điện thoại không hợp lệ.";
        if (application.Products.Length is < 1 or > 8 || application.Products.Any(p => p.Length is < 1 or > 40 || !Input.Safe(p)) || application.Products.Distinct(StringComparer.Ordinal).Count() != application.Products.Length ||
            await db.Products.CountAsync(p => application.Products.Contains(p.Code), ct) != application.Products.Length) return "Chọn từ 1 đến 8 sản phẩm trong danh mục, không trùng lặp.";
        if (application.RequestedRole == AccountRole.Producer)
        {
            if (application.CultivatedAreaHa is null or <= 0 or > 1000000 || decimal.Round(application.CultivatedAreaHa.Value, 3) != application.CultivatedAreaHa || application.TaxCode is not null || application.BusinessRegistrationNumber is not null) return "Nhà vườn cần diện tích canh tác dương, tối đa 3 chữ số thập phân; không khai mã đăng ký thương lái.";
        }
        else if (application.CultivatedAreaHa is not null || (application.TaxCode is null && application.BusinessRegistrationNumber is null)) return "Thương lái cần mã số thuế hoặc số đăng ký kinh doanh và không khai diện tích canh tác.";
        if ((application.TaxCode is not null && !RegistrationValue(application.TaxCode, 40)) || (application.BusinessRegistrationNumber is not null && !RegistrationValue(application.BusinessRegistrationNumber, 80))) return "Mã số thuế hoặc đăng ký kinh doanh không hợp lệ.";
        var location = await ValidateLocation(services, application.CountryCode, application.ProvinceCode, ct);
        application.CountryCode = location.CountryCode;
        application.ProvinceCode = location.ProvinceCode;
        application.Region = location.Region;
        return null;
    }

    private static bool RegistrationValue(string value, int max) => value.Length >= 2 && value.Length <= max && Input.Safe(value) && value.All(c => char.IsAsciiLetterOrDigit(c) || c is ' ' or '-' or '_' or '/' or '.');

    private static Task<ValidatedLocation> ValidateLocation(IServiceProvider services, string countryCode, string provinceCode, CancellationToken ct) =>
        services.GetRequiredService<LocationDirectory>().ValidateAsync(countryCode, provinceCode, ct);

    private static async Task<IResult> Submit(Guid id, RoleApplicationSubmitRequest request, HttpContext http, AppDbContext db, RoleEvidenceStorage storage, CancellationToken ct)
    {
        await using var tx = await db.Database.BeginTransactionAsync(ct);
        var user = await LockUser(db, http.User.UserId(), ct);
        if (!Eligible(user)) return Input.Denied();
        var application = await LockApplication(db, id, ct);
        if (application is null || application.UserId != user!.Id) return Results.NotFound();
        if (!Editable(application) || application.Revision != request.ExpectedRevision) return Results.Conflict();
        if (!Active(application) && await db.Set<RoleApplication>().AnyAsync(a => a.UserId == user.Id && a.Id != id && (a.Status == "Draft" || a.Status == "Submitted" || a.Status == "NeedsInformation"), ct)) return Results.Conflict();
        if (await ProfileError(application, db, http.RequestServices, ct) is not null || !await HasProof(db, storage, application, ct)) return Results.Conflict(new { title = "Hoàn thiện thông tin và tải ít nhất một minh chứng phù hợp trước khi gửi." });
        application.Status = "Submitted"; application.SubmittedAt = DateTimeOffset.UtcNow; Changed(application);
        db.AuditEntries.Add(SessionTokens.Audit(user.Id, user.Id, "RoleApplicationSubmitted"));
        db.InteractionHistories.Add(new() { UserId = user.Id, Kind = "RoleApplicationSubmitted", Title = "Đã gửi hồ sơ nâng vai trò", Body = application.RequestedRole.ToString() });
        await db.SaveChangesAsync(ct);
        var view = await View(db, application, ct);
        await tx.CommitAsync(ct);
        await Notify(http, application);
        return Results.Ok(view);
    }

    private static async Task<bool> HasProof(AppDbContext db, RoleEvidenceStorage storage, RoleApplication application, CancellationToken ct)
    {
        var category = Category(application);
        var evidence = await db.Set<RoleApplicationEvidence>().AsNoTracking().Where(e => e.ApplicationId == application.Id && e.Category == category).ToListAsync(ct);
        foreach (var item in evidence) { await using var file = await storage.OpenAsync(item, ct); if (file is not null) return true; }
        return false;
    }

    private static async Task<IResult> Upload(Guid id, string category, int expectedRevision, HttpContext http, AppDbContext db, RoleEvidenceStorage storage, CancellationToken ct)
    {
        await using var tx = await db.Database.BeginTransactionAsync(ct);
        var user = await LockUser(db, http.User.UserId(), ct);
        if (!Eligible(user)) return Input.Denied();
        var application = await LockApplication(db, id, ct);
        if (application is null || application.UserId != user!.Id) return Results.NotFound();
        if (expectedRevision < 1) return Input.Invalid("expectedRevision phải là số nguyên dương.");
        if (!Editable(application) || application.Revision != expectedRevision) return Results.Conflict();
        if (http.Request.ContentLength > RoleEvidenceStorage.MaximumBytes) return Results.StatusCode(413);
        if (category != Category(application) || RoleEvidenceStorage.Extension(http.Request.ContentType) is null) return Input.Invalid("Loại minh chứng hoặc kiểu tệp không phù hợp.");
        if (await db.Set<RoleApplicationEvidence>().CountAsync(e => e.ApplicationId == id, ct) >= 4) return Results.Conflict();
        var evidence = new RoleApplicationEvidence { ApplicationId = id, Category = category, ContentType = http.Request.ContentType! };
        var committed = false;
        try
        {
            var bodyLimit = http.Features.Get<Microsoft.AspNetCore.Http.Features.IHttpMaxRequestBodySizeFeature>();
            if (bodyLimit is { IsReadOnly: false }) bodyLimit.MaxRequestBodySize = RoleEvidenceStorage.MaximumBytes;
            await storage.SaveAsync(evidence, http.Request.Body, ct);
            db.Add(evidence); Changed(application);
            db.AuditEntries.Add(SessionTokens.Audit(user.Id, user.Id, "RoleEvidenceAdded", evidence.Id.ToString()));
            await db.SaveChangesAsync(ct);
            var view = await View(db, application, ct);
            await tx.CommitAsync(ct); committed = true;
            await Notify(http, application);
            return Results.Created($"/api/v1/role-applications/{id}/evidence/{evidence.Id}", view);
        }
        catch (RoleEvidenceException exception) { return Results.Problem(statusCode: exception.Status, title: exception.Message); }
        finally { if (!committed) storage.Remove(evidence); }
    }

    private static async Task<IResult> DeleteEvidence(Guid id, Guid evidenceId, int expectedRevision, HttpContext http, AppDbContext db, RoleEvidenceStorage storage, CancellationToken ct)
    {
        await using var tx = await db.Database.BeginTransactionAsync(ct);
        var user = await LockUser(db, http.User.UserId(), ct);
        if (!Eligible(user)) return Input.Denied();
        var application = await LockApplication(db, id, ct);
        if (application is null || application.UserId != user!.Id) return Results.NotFound();
        if (expectedRevision < 1) return Input.Invalid("expectedRevision phải là số nguyên dương.");
        if (!Editable(application) || application.Revision != expectedRevision) return Results.Conflict();
        var evidence = await db.Set<RoleApplicationEvidence>().SingleOrDefaultAsync(e => e.Id == evidenceId && e.ApplicationId == id, ct);
        if (evidence is null) return Results.NotFound();
        db.Remove(evidence); Changed(application);
        db.AuditEntries.Add(SessionTokens.Audit(user!.Id, user.Id, "RoleEvidenceRemoved", evidence.Id.ToString()));
        await db.SaveChangesAsync(ct);
        var view = await View(db, application, ct);
        await tx.CommitAsync(ct);
        storage.Remove(evidence);
        await Notify(http, application);
        return Results.Ok(view);
    }

    private static async Task<IResult> DownloadEvidence(Guid id, Guid evidenceId, HttpContext http, AppDbContext db, RoleEvidenceStorage storage, CancellationToken ct)
    {
        var application = await db.Set<RoleApplication>().AsNoTracking().SingleOrDefaultAsync(a => a.Id == id, ct);
        if (application is null || (application.UserId != http.User.UserId() && !IsAdmin(http))) return Results.NotFound();
        var evidence = await db.Set<RoleApplicationEvidence>().AsNoTracking().SingleOrDefaultAsync(e => e.Id == evidenceId && e.ApplicationId == id, ct);
        if (evidence is null) return Results.NotFound();
        var stream = await storage.OpenAsync(evidence, ct);
        if (stream is null) return Results.NotFound();
        http.Response.Headers.ContentSecurityPolicy = "default-src 'none'; sandbox";
        return Results.File(stream, evidence.ContentType, $"evidence_{evidence.Id:N}{RoleEvidenceStorage.Extension(evidence.ContentType)}");
    }

    private static async Task<IResult> Review(Guid id, RoleApplicationReviewRequest request, HttpContext http, AppDbContext db, RoleEvidenceStorage storage, SessionConnections connections, CancellationToken ct)
    {
        if (request.Status is not ("Approved" or "NeedsInformation" or "Rejected") || !Input.Safe(request.Reason, true) || Input.Text(request.Reason).Length < 3) return Input.Invalid("Kết quả hoặc lý do xét duyệt không hợp lệ.");
        var subject = await db.Set<RoleApplication>().AsNoTracking().Where(a => a.Id == id).Select(a => (Guid?)a.UserId).SingleOrDefaultAsync(ct);
        if (!subject.HasValue) return Results.NotFound();
        await using var tx = await db.Database.BeginTransactionAsync(ct);
        var user = await LockUser(db, subject.Value, ct);
        var application = await LockApplication(db, id, ct);
        if (application is null || application.Status != "Submitted" || application.Revision != request.ExpectedRevision) return Results.Conflict();
        if (request.Status == "Approved")
        {
            if (!Eligible(user) || await ProfileError(application, db, http.RequestServices, ct) is not null || !await HasProof(db, storage, application, ct)) return Results.Conflict();
            user!.Role = application.RequestedRole;
            user.ApprovalStatus = ApprovalState.Approved;
            user.Region = application.Region;
            user.CountryCode = application.CountryCode;
            user.ProvinceCode = application.ProvinceCode;
        }
        application.Status = request.Status; application.ReviewReason = Input.Text(request.Reason);
        application.ReviewedAt = DateTimeOffset.UtcNow; application.ReviewedById = http.User.UserId(); Changed(application);
        db.AuditEntries.Add(SessionTokens.Audit(http.User.UserId(), subject.Value, "RoleApplication" + request.Status, application.ReviewReason));
        db.InteractionHistories.Add(new() { UserId = subject.Value, Kind = "RoleApplicationReviewed", Title = "Kết quả hồ sơ nâng vai trò", Body = application.ReviewReason });
        await db.SaveChangesAsync(ct);
        var view = await View(db, application, ct);
        await tx.CommitAsync(ct);
        await Notify(http, application);
        if (request.Status == "Approved") connections.AbortUser(subject.Value);
        return Results.Ok(view);
    }

    private static async Task<RoleApplicationView> View(AppDbContext db, RoleApplication application, CancellationToken ct) =>
        ToView(application, await db.Set<RoleApplicationEvidence>().AsNoTracking().Where(e => e.ApplicationId == application.Id).OrderBy(e => e.CreatedAt).ThenBy(e => e.Id).ToListAsync(ct),
            await db.Users.AsNoTracking().SingleAsync(u => u.Id == application.UserId, ct));
    private static RoleApplicationView ToView(RoleApplication a, IEnumerable<RoleApplicationEvidence> evidence, AppUser applicant) => new(a.Id, a.UserId, a.RequestedRole.ToString(), a.Status, a.Revision,
        a.OrganisationName, a.Address, a.CountryCode, a.ProvinceCode, a.Region, a.Phone, a.Products, a.CultivatedAreaHa, a.TaxCode, a.BusinessRegistrationNumber, a.CreatedAt, a.UpdatedAt, a.SubmittedAt, a.ReviewedAt, a.ReviewReason,
        evidence.Select(e => new RoleApplicationEvidenceView(e.Id, e.Category, e.ContentType, e.SizeBytes, e.CreatedAt, $"/api/v1/role-applications/{a.Id}/evidence/{e.Id}")).ToArray(),
        new(applicant.Id, applicant.DisplayName, applicant.Role.ToString()));

    private static async Task Notify(HttpContext http, RoleApplication application)
    {
        try
        {
            await http.RequestServices.GetRequiredService<IHubContext<FruitHub>>().Clients.Groups(new[] { $"user:{application.UserId}", "role:Admin" })
                .SendAsync("RoleApplicationChanged", new { eventId = Guid.NewGuid(), id = application.Id, status = application.Status, revision = application.Revision });
        }
        catch (Exception exception)
        {
            http.RequestServices.GetRequiredService<ILoggerFactory>().CreateLogger("RoleApplications")
                .LogWarning("Role application {ApplicationId} notification was not delivered ({FailureType}).", application.Id, exception.GetType().Name);
        }
    }
}
