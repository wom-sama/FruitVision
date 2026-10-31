using FruitVision.Api.Auth;
using FruitVision.Api.Contracts;
using FruitVision.Api.Data;
using FruitVision.Api.Infrastructure;
using Microsoft.EntityFrameworkCore;

namespace FruitVision.Api.Features;

public static class ProfileEndpoints
{
    public static void MapProfiles(this WebApplication app)
    {
        app.MapGet("/api/v1/profile", Own).RequireAuthorization();
        app.MapPut("/api/v1/profile", Edit).RequireAuthorization().AddEndpointFilter<InputFilter>();
        app.MapGet("/api/v1/profiles/{id:guid}", Public).RequireAuthorization("Approved");
        app.MapGet("/api/v1/profile/blocked", async (HttpContext http, AppDbContext db, CancellationToken ct) =>
        {
            var uid = http.User.UserId();
            var users = await (from block in db.Set<UserBlock>().AsNoTracking()
                               join user in db.Users.AsNoTracking() on block.BlockedUserId equals user.Id
                               where block.OwnerUserId == uid
                               orderby block.CreatedAt descending, block.BlockedUserId
                               select new { user.Id, user.DisplayName, user.Role }).ToListAsync(ct);
            return Results.Ok(new { items = users.Select(u => new { u.Id, u.DisplayName, role = u.Role.ToString() }) });
        }).RequireAuthorization("Approved");
        app.MapPut("/api/v1/profiles/{id:guid}/block", (Guid id, HttpContext http, AppDbContext db, CancellationToken ct) => Block(id, true, http, db, ct)).RequireAuthorization("Approved");
        app.MapDelete("/api/v1/profiles/{id:guid}/block", (Guid id, HttpContext http, AppDbContext db, CancellationToken ct) => Block(id, false, http, db, ct)).RequireAuthorization("Approved");
    }

    private static async Task<object> RoleDetails(AppDbContext db, AppUser user, CancellationToken ct)
    {
        var establishmentName = user.Role is AccountRole.Producer or AccountRole.Trader
            ? await db.Set<SellerBranch>().AsNoTracking().Where(b => b.OwnerId == user.Id && b.Status == "Approved")
                .OrderBy(b => b.CreatedAt).ThenBy(b => b.Id).Select(b => b.Name).FirstOrDefaultAsync(ct) : null;
        return new { role = user.Role.ToString(), approvalStatus = user.ApprovalStatus.ToString(), establishmentName };
    }

    private static async Task<object> OwnView(AppDbContext db, AppUser user, UserProfile profile, CancellationToken ct)
    {
        var application = await db.Set<RoleApplication>().AsNoTracking().Where(a => a.UserId == user.Id)
            .OrderByDescending(a => a.CreatedAt).ThenByDescending(a => a.Id)
            .Select(a => new { a.Id, a.Status, requestedRole = a.RequestedRole.ToString() }).FirstOrDefaultAsync(ct);
        return new { user.Id, user.DisplayName, role = user.Role.ToString(), approvalStatus = user.ApprovalStatus.ToString(),
            user.Email, profile.Phone, profile.Gender, profile.Bio, user.Region, profile.ShowGender, profile.ShowPhone, profile.ShowRegion,
            roleDetails = await RoleDetails(db, user, ct), roleApplication = application };
    }

    private static async Task<IResult> Own(HttpContext http, AppDbContext db, CancellationToken ct)
    {
        var uid = http.User.UserId(); var user = await db.Users.AsNoTracking().SingleAsync(u => u.Id == uid, ct);
        var profile = await db.Set<UserProfile>().AsNoTracking().SingleOrDefaultAsync(p => p.UserId == uid, ct) ?? new UserProfile { UserId = uid };
        http.Response.Headers.CacheControl = "no-store";
        return Results.Ok(await OwnView(db, user, profile, ct));
    }

    private static async Task<IResult> Public(Guid id, HttpContext http, AppDbContext db, CancellationToken ct)
    {
        var uid = http.User.UserId();
        if (await ProfileBlocks.IsEitherBlockedAsync(db, uid, id, ct)) return Results.NotFound();
        var user = await db.Users.AsNoTracking().SingleOrDefaultAsync(u => u.Id == id && u.IsActive && u.ApprovalStatus == ApprovalState.Approved, ct);
        if (user is null) return Results.NotFound();
        var profile = await db.Set<UserProfile>().AsNoTracking().SingleOrDefaultAsync(p => p.UserId == id, ct) ?? new UserProfile { UserId = id };
        http.Response.Headers.CacheControl = "no-store";
        return Results.Ok(new { user.Id, user.DisplayName, role = user.Role.ToString(), profile.Bio,
            region = profile.ShowRegion ? user.Region : null, gender = profile.ShowGender ? profile.Gender : null,
            phone = profile.ShowPhone ? profile.Phone : null, roleDetails = await RoleDetails(db, user, ct) });
    }

    private static async Task<IResult> Edit(UpdateProfileRequest request, HttpContext http, AppDbContext db, CancellationToken ct)
    {
        var name = Input.Text(request.DisplayName); var bio = Input.Text(request.Bio ?? ""); var phone = Input.Text(request.Phone ?? "");
        if (name.Length is < 2 or > 100 || bio.Length > 500 || phone.Length > 30 || !Input.Safe(name) || !Input.Safe(bio, true) || !Input.Safe(phone) ||
            (phone.Length > 0 && (phone.Count(char.IsAsciiDigit) < 6 || !phone.All(c => char.IsAsciiDigit(c) || c is '+' or ' ' or '-' or '(' or ')'))))
            return Input.Invalid("Tên từ 2–100 ký tự, giới thiệu tối đa 500, điện thoại tối đa 30 ký tự hợp lệ.");
        var uid = http.User.UserId(); await using var tx = await db.Database.BeginTransactionAsync(ct);
        var user = await db.Users.FromSqlInterpolated($"SELECT * FROM \"AspNetUsers\" WHERE \"Id\"={uid} FOR UPDATE").SingleAsync(ct);
        if (!user.IsActive) return Results.Forbid();
        var profile = await db.Set<UserProfile>().SingleOrDefaultAsync(p => p.UserId == uid, ct);
        if (profile is null) { profile = new UserProfile { UserId = uid }; db.Add(profile); }
        user.DisplayName = name; profile.Bio = bio; profile.Phone = phone.Length == 0 ? null : phone; profile.Gender = request.Gender;
        profile.ShowGender = request.ShowGender; profile.ShowPhone = request.ShowPhone; profile.ShowRegion = request.ShowRegion; profile.UpdatedAt = DateTimeOffset.UtcNow;
        db.AuditEntries.Add(SessionTokens.Audit(uid, uid, "ProfileUpdated"));
        await db.SaveChangesAsync(ct); await tx.CommitAsync(ct); http.Response.Headers.CacheControl = "no-store";
        return Results.Ok(await OwnView(db, user, profile, ct));
    }

    private static async Task<IResult> Block(Guid id, bool blocked, HttpContext http, AppDbContext db, CancellationToken ct)
    {
        var uid = http.User.UserId(); if (id == uid || id == Guid.Empty) return Input.Invalid("Chọn một tài khoản khác.");
        await using var tx = await db.Database.BeginTransactionAsync(ct);
        var users = await db.Users.FromSqlInterpolated($"SELECT * FROM \"AspNetUsers\" WHERE \"Id\"={uid} OR \"Id\"={id} ORDER BY \"Id\" FOR UPDATE").ToListAsync(ct);
        if (!users.Any(u => u.Id == uid && u.IsActive && u.ApprovalStatus == ApprovalState.Approved)) return Results.Forbid();
        // Revoking an existing own block remains possible if the target was later suspended.
        var entry = await db.Set<UserBlock>().SingleOrDefaultAsync(b => b.OwnerUserId == uid && b.BlockedUserId == id, ct);
        if (blocked && !users.Any(u => u.Id == id && u.IsActive && u.ApprovalStatus == ApprovalState.Approved)) return Results.NotFound();
        if (blocked && entry is null) db.Add(new UserBlock { OwnerUserId = uid, BlockedUserId = id });
        else if (!blocked && entry is not null) db.Remove(entry);
        if ((blocked && entry is null) || (!blocked && entry is not null)) db.AuditEntries.Add(SessionTokens.Audit(uid, id, blocked ? "UserBlocked" : "UserUnblocked"));
        await db.SaveChangesAsync(ct); await tx.CommitAsync(ct);
        return blocked ? Results.Ok(new { id, blocked = true }) : Results.NoContent();
    }
}
