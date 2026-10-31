using FruitVision.Api.Auth;
using FruitVision.Api.Contracts;
using FruitVision.Api.Data;
using FruitVision.Api.Infrastructure;
using FruitVision.Api.Realtime;
using Microsoft.AspNetCore.Identity;
using Microsoft.AspNetCore.SignalR;
using Microsoft.EntityFrameworkCore;

namespace FruitVision.Api.Features;

public static class AdminAppointmentEndpoints
{
    public static void MapAdminAppointments(this WebApplication app)
    {
        var admin = app.MapGroup("/api/v1/admin").RequireAuthorization("Admin").WithTags("Bổ nhiệm quản trị viên");
        admin.MapGet("/admin-candidates", Candidates);
        admin.MapPost("/admin-appointments", Appoint).RequireRateLimiting("auth").AddEndpointFilter<InputFilter>();
    }

    private static bool Active(AppUser user) => user.IsActive && user.EmailConfirmed && user.ApprovalStatus == ApprovalState.Approved &&
        !(user.LockoutEnd > DateTimeOffset.UtcNow);
    private static IResult InvalidPassword() => Results.Problem(statusCode: 403, title: "Không xác nhận được thông tin đăng nhập.");

    private static async Task<IResult> Candidates(string? search, int? limit, AppDbContext db, CancellationToken ct)
    {
        if (!Input.Page(limit, out var size) || (search is not null && (search.Length > 100 || !Input.Safe(search))))
            return Input.Invalid("Từ khóa tối đa 100 ký tự; limit từ 1 đến 50.");
        var now = DateTimeOffset.UtcNow;
        var query = db.Users.AsNoTracking().Where(u => u.Role == AccountRole.Consumer && u.IsActive && u.EmailConfirmed &&
            u.ApprovalStatus == ApprovalState.Approved && u.Email != null && (u.LockoutEnd == null || u.LockoutEnd <= now));
        if (!string.IsNullOrWhiteSpace(search))
        {
            var term = Input.Text(search).ToLowerInvariant();
            query = query.Where(u => u.DisplayName.ToLower().Contains(term) || u.Email!.ToLower().Contains(term));
        }
        return Results.Ok(new { items = await query.OrderBy(u => u.DisplayName).ThenBy(u => u.Id).Take(size)
            .Select(u => new { u.Id, u.DisplayName, u.Email, u.Region }).ToListAsync(ct) });
    }

    private static async Task<IResult> Appoint(CreateAdminAppointmentRequest request, HttpContext http, AppDbContext db,
        UserManager<AppUser> users, SessionConnections connections, IHubContext<FruitHub> hub, ILoggerFactory logs, CancellationToken ct)
    {
        if (request.UserId == Guid.Empty || !Input.Safe(request.Reason, true) || Input.Text(request.Reason).Length is < 3 or > 1000)
            return Input.Invalid("Cần tài khoản đích và lý do 3–1000 ký tự hợp lệ.");
        var actorId = http.User.UserId(); var targetId = request.UserId;
        await using var tx = await db.Database.BeginTransactionAsync(ct);
        // Canonical ordering also covers two Admins concurrently selecting one another.
        var locked = await db.Users.FromSqlInterpolated($"SELECT * FROM \"AspNetUsers\" WHERE \"Id\"={actorId} OR \"Id\"={targetId} ORDER BY \"Id\" FOR UPDATE").ToListAsync(ct);
        var actor = locked.SingleOrDefault(u => u.Id == actorId);
        if (actor is null || actor.Role != AccountRole.Admin || !Active(actor)) return Results.Forbid();
        // Do not trim, normalize or log this password. 403 prevents the API client from
        // refreshing/retrying a failed reconfirmation and counting the same guess twice.
        if (!await users.CheckPasswordAsync(actor, request.Password))
        {
            var failed = await users.AccessFailedAsync(actor);
            if (!failed.Succeeded) return Results.Problem(statusCode: 409, title: "Trạng thái tài khoản đã thay đổi; hãy đăng nhập lại.");
            var lockedOut = await users.IsLockedOutAsync(actor);
            if (lockedOut)
                await db.AuthSessions.Where(s => s.UserId == actorId && s.RevokedAt == null).ExecuteUpdateAsync(set => set.SetProperty(s => s.RevokedAt, DateTimeOffset.UtcNow), ct);
            await tx.CommitAsync(ct);
            if (lockedOut) connections.AbortUser(actorId);
            return InvalidPassword();
        }
        var target = locked.SingleOrDefault(u => u.Id == targetId);
        if (target is null) return Results.NotFound();
        if (targetId == actorId || target.Role != AccountRole.Consumer || !Active(target) || string.IsNullOrWhiteSpace(target.Email))
            return Results.Conflict(new { message = "Chỉ bổ nhiệm Consumer đang hoạt động, đã duyệt và xác minh email; không đổi vai trò Admin/Seller hiện có." });
        var reset = await users.ResetAccessFailedCountAsync(actor);
        if (!reset.Succeeded) return Results.Conflict(new { message = "Trạng thái quản trị viên đã thay đổi; hãy đăng nhập lại." });
        target.Role = AccountRole.Admin;
        target.ConcurrencyStamp = Guid.NewGuid().ToString("N");
        var updated = await users.UpdateSecurityStampAsync(target);
        if (!updated.Succeeded) return Results.Conflict(new { message = "Tài khoản đích đã thay đổi; hãy tải lại danh sách." });
        await db.AuthSessions.Where(s => s.UserId == targetId && s.RevokedAt == null).ExecuteUpdateAsync(set => set.SetProperty(s => s.RevokedAt, DateTimeOffset.UtcNow), ct);
        db.AuditEntries.Add(SessionTokens.Audit(actorId, targetId, "AdminAppointed", Input.Text(request.Reason)));
        await db.SaveChangesAsync(ct);
        var result = new { target.Id, target.DisplayName, target.Email, target.Region, role = target.Role.ToString() };
        await tx.CommitAsync(ct);
        try
        {
            await hub.Clients.Groups(new[] { $"user:{targetId}", "role:Admin" }).SendAsync("AccountRoleChanged", new { eventId = Guid.NewGuid(), id = targetId, role = "Admin" });
        }
        catch (Exception exception)
        { logs.CreateLogger("AdminAppointments").LogWarning("Account {UserId} role notification was not delivered ({FailureType}).", targetId, exception.GetType().Name); }
        connections.AbortUser(targetId);
        return Results.Ok(result);
    }
}
