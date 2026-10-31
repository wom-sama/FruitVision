using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text.Json;
using FruitVision.Api.Data;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
using Xunit;

namespace FruitVision.Tests;

[Collection("Api")]
public sealed class AdminAppointmentTests(ApiFixture fixture)
{
    [Fact]
    public async Task Candidate_search_returns_only_active_approved_confirmed_consumers_and_admin_safe_fields()
    {
        using var admin = fixture.CreateClient(); await Login(admin, "Admin"); var tag = "Candidate-" + Guid.NewGuid().ToString("N");
        var eligible = await Account(name: tag + " eligible"); var pending = await Account(approve: false, name: tag + " pending");
        var unverified = await Account(name: tag + " unverified"); var inactive = await Account(name: tag + " inactive"); await Account("Producer", name: tag + " seller"); await Account("Admin", name: tag + " admin");
        using (var scope = fixture.Services.CreateScope()) { var db = scope.ServiceProvider.GetRequiredService<AppDbContext>(); (await db.Users.SingleAsync(u => u.Id == unverified.Id)).EmailConfirmed = false; (await db.Users.SingleAsync(u => u.Id == inactive.Id)).IsActive = false; await db.SaveChangesAsync(); }
        using var response = await admin.GetAsync("/api/v1/admin/admin-candidates?search=" + Uri.EscapeDataString(tag) + "&limit=20"); Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        var row = Assert.Single((await response.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("items").EnumerateArray()); Assert.Equal(eligible.Id, row.GetProperty("id").GetGuid()); Assert.Equal(eligible.Email, row.GetProperty("email").GetString());
        Assert.Equal(new[] { "displayName", "email", "id", "region" }, row.EnumerateObject().Select(p => p.Name).Order().ToArray());
        using var invalid = await admin.GetAsync("/api/v1/admin/admin-candidates?limit=51"); Assert.Equal(HttpStatusCode.BadRequest, invalid.StatusCode);
    }

    [Fact]
    public async Task Exact_actor_password_promotes_consumer_once_revokes_sessions_and_records_no_password()
    {
        var exact = fixture.Password + " "; using var admin = fixture.CreateClient(); var actor = await Login(admin, "Admin", password: exact);
        using var targetClient = fixture.CreateClient(); var target = await Login(targetClient); string? stamp; string? concurrency;
        using (var scope = fixture.Services.CreateScope()) { var user = await scope.ServiceProvider.GetRequiredService<AppDbContext>().Users.AsNoTracking().SingleAsync(u => u.Id == target.Id); stamp = user.SecurityStamp; concurrency = user.ConcurrencyStamp; }
        using var wrong = await admin.PostAsJsonAsync("/api/v1/admin/admin-appointments", new { userId = target.Id, password = exact.Trim(), reason = "Isolated technical appointment" }); Assert.Equal(HttpStatusCode.Forbidden, wrong.StatusCode);
        using var result = await admin.PostAsJsonAsync("/api/v1/admin/admin-appointments", new { userId = target.Id, password = exact, reason = "Isolated technical appointment" }); Assert.Equal(HttpStatusCode.OK, result.StatusCode);
        var view = await result.Content.ReadFromJsonAsync<JsonElement>(); Assert.Equal(target.Id, view.GetProperty("id").GetGuid()); Assert.Equal("Admin", view.GetProperty("role").GetString()); Assert.False(view.GetRawText().Contains(exact, StringComparison.Ordinal));
        using var revoked = await targetClient.GetAsync("/api/v1/auth/me"); Assert.Equal(HttpStatusCode.Unauthorized, revoked.StatusCode);
        using var savedScope = fixture.Services.CreateScope(); var db = savedScope.ServiceProvider.GetRequiredService<AppDbContext>();
        var saved = await db.Users.SingleAsync(u => u.Id == target.Id); Assert.Equal(AccountRole.Admin, saved.Role); Assert.True(saved.SecurityStamp != stamp); Assert.True(saved.ConcurrencyStamp != concurrency);
        Assert.All(await db.AuthSessions.Where(s => s.UserId == target.Id).ToListAsync(), session => Assert.NotNull(session.RevokedAt));
        var audit = Assert.Single(await db.AuditEntries.Where(a => a.Action == "AdminAppointed" && a.SubjectId == target.Id).ToListAsync()); Assert.Equal(actor.Id, audit.ActorId); Assert.True(audit.Reason == "Isolated technical appointment"); Assert.False(audit.Reason?.Contains(exact, StringComparison.Ordinal) ?? false);
    }

    [Fact]
    public async Task Concurrent_appointments_have_one_success_and_all_ineligible_or_self_targets_conflict()
    {
        using var admin = fixture.CreateClient(); var actor = await Login(admin, "Admin"); var target = await Account();
        var body = new { userId = target.Id, password = fixture.Password, reason = "Concurrent isolated appointment" };
        var replies = await Task.WhenAll(admin.PostAsJsonAsync("/api/v1/admin/admin-appointments", body), admin.PostAsJsonAsync("/api/v1/admin/admin-appointments", body));
        try { Assert.Single(replies, r => r.StatusCode == HttpStatusCode.OK); Assert.Single(replies, r => r.StatusCode == HttpStatusCode.Conflict); } finally { foreach (var r in replies) r.Dispose(); }
        var inactive = await Account(); var unverified = await Account(); var pending = await Account(approve: false); var seller = await Account("Trader");
        using (var scope = fixture.Services.CreateScope()) { var db = scope.ServiceProvider.GetRequiredService<AppDbContext>(); (await db.Users.SingleAsync(u => u.Id == inactive.Id)).IsActive = false; (await db.Users.SingleAsync(u => u.Id == unverified.Id)).EmailConfirmed = false; await db.SaveChangesAsync(); }
        foreach (var id in new[] { actor.Id, target.Id, inactive.Id, unverified.Id, pending.Id, seller.Id })
        { using var response = await admin.PostAsJsonAsync("/api/v1/admin/admin-appointments", new { userId = id, password = fixture.Password, reason = "Never demote or bypass target eligibility" }); Assert.Equal(HttpStatusCode.Conflict, response.StatusCode); }
        using var missing = await admin.PostAsJsonAsync("/api/v1/admin/admin-appointments", new { userId = Guid.NewGuid(), password = fixture.Password, reason = "Unknown target" }); Assert.Equal(HttpStatusCode.NotFound, missing.StatusCode);
        using var auditScope = fixture.Services.CreateScope(); Assert.Equal(1, await auditScope.ServiceProvider.GetRequiredService<AppDbContext>().AuditEntries.CountAsync(a => a.Action == "AdminAppointed" && a.SubjectId == target.Id));
    }

    [Fact]
    public async Task Wrong_password_counts_toward_actor_lockout_and_never_changes_target()
    {
        using var admin = fixture.CreateClient(); var actor = await Login(admin, "Admin"); var target = await Account();
        for (var i = 0; i < 5; i++)
        {
            using var response = await admin.PostAsJsonAsync("/api/v1/admin/admin-appointments", new { userId = target.Id, password = "Incorrect confirmation value", reason = "Wrong confirmation must never appoint" }); Assert.Equal(HttpStatusCode.Forbidden, response.StatusCode);
        }
        using var denied = await admin.GetAsync("/api/v1/auth/me"); Assert.Equal(HttpStatusCode.Unauthorized, denied.StatusCode);
        using var scope = fixture.Services.CreateScope(); var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
        Assert.True((await db.Users.SingleAsync(u => u.Id == actor.Id)).LockoutEnd > DateTimeOffset.UtcNow); Assert.Equal(AccountRole.Consumer, (await db.Users.SingleAsync(u => u.Id == target.Id)).Role); Assert.False(await db.AuditEntries.AnyAsync(a => a.Action == "AdminAppointed" && a.SubjectId == target.Id));
    }

    [Theory]
    [InlineData("Consumer")]
    [InlineData("Producer")]
    [InlineData("Trader")]
    public async Task Non_admins_cannot_search_or_appoint_even_with_correct_password(string role)
    {
        using var client = fixture.CreateClient(); await Login(client, role); var target = await Account();
        using var list = await client.GetAsync("/api/v1/admin/admin-candidates"); Assert.Equal(HttpStatusCode.Forbidden, list.StatusCode);
        using var write = await client.PostAsJsonAsync("/api/v1/admin/admin-appointments", new { userId = target.Id, password = fixture.Password, reason = "Only current Admin may appoint" }); Assert.Equal(HttpStatusCode.Forbidden, write.StatusCode);
    }

    private Task<TestAccount> Account(string role = "Consumer", bool approve = true, string name = "Appointment fixture", string? password = null) => TestAccounts.CreateAsync(fixture.Services, password ?? fixture.Password, role, approve, name);
    private async Task<TestAccount> Login(HttpClient client, string role = "Consumer", string? password = null)
    { var account = await Account(role, password: password); using var response = await client.PostAsJsonAsync("/api/v1/auth/login", new { email = account.Email, password = password ?? fixture.Password }); Assert.Equal(HttpStatusCode.OK, response.StatusCode); client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", (await response.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("accessToken").GetString()); return account; }
}
