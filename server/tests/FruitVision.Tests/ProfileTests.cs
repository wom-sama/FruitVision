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
public sealed class ProfileTests(ApiFixture fixture)
{
    [Fact]
    public async Task Private_profile_updates_common_fields_and_public_fields_require_individual_opt_in()
    {
        using var owner = await Actor("Producer"); using var reader = await Actor("Consumer");
        using var update = await owner.Http.PutAsJsonAsync("/api/v1/profile", Edit("Profile owner", "Female", "0901234567", false));
        Assert.Equal(HttpStatusCode.OK, update.StatusCode);
        var own = await update.Content.ReadFromJsonAsync<JsonElement>(); Assert.Equal("0901234567", own.GetProperty("phone").GetString()); Assert.True(own.TryGetProperty("email", out _));
        var publicView = await reader.Http.GetFromJsonAsync<JsonElement>($"/api/v1/profiles/{owner.Id}");
        Assert.Equal("Profile owner", publicView.GetProperty("displayName").GetString());
        foreach (var field in new[] { "phone", "gender", "region" }) Assert.Equal(JsonValueKind.Null, publicView.GetProperty(field).ValueKind);
        foreach (var field in new[] { "email", "reviewReason", "taxCode", "businessRegistrationNumber", "address" }) Assert.False(publicView.TryGetProperty(field, out _));
        Assert.Equal(new[] { "approvalStatus", "establishmentName", "role" }, publicView.GetProperty("roleDetails").EnumerateObject().Select(p => p.Name).Order().ToArray());
        using var optedIn = await owner.Http.PutAsJsonAsync("/api/v1/profile", Edit("Profile owner", "Female", "0901234567", true)); Assert.Equal(HttpStatusCode.OK, optedIn.StatusCode);
        var visible = await reader.Http.GetFromJsonAsync<JsonElement>($"/api/v1/profiles/{owner.Id}"); Assert.Equal("Female", visible.GetProperty("gender").GetString()); Assert.Equal("0901234567", visible.GetProperty("phone").GetString());
    }

    [Fact]
    public async Task Validation_and_unknown_fields_cannot_change_roles_approval_or_private_legal_profiles()
    {
        using var owner = await Actor("Consumer");
        foreach (var payload in new object[] { Edit("x"), Edit(new string('x', 101)), Edit("Valid name", "Invalid"),
            new { displayName = "Valid name", gender = "Unknown", bio = new string('x', 501) },
            new { displayName = "Valid name", gender = "Unknown", phone = "not a phone" },
            new { displayName = "Valid name", gender = "Unknown", role = "Admin", approvalStatus = "Approved" } })
        { using var response = await owner.Http.PutAsJsonAsync("/api/v1/profile", payload); Assert.Equal(HttpStatusCode.BadRequest, response.StatusCode); }
        var unchanged = await owner.Http.GetFromJsonAsync<JsonElement>("/api/v1/profile"); Assert.Equal("Consumer", unchanged.GetProperty("role").GetString());
        using var pending = await Actor("Trader", false); using var publicDenied = await pending.Http.GetAsync($"/api/v1/profiles/{owner.Id}"); Assert.Equal(HttpStatusCode.Forbidden, publicDenied.StatusCode);
        using var ownPending = await pending.Http.GetAsync("/api/v1/profile"); Assert.Equal(HttpStatusCode.OK, ownPending.StatusCode);
    }

    [Fact]
    public async Task Both_direction_block_hides_profiles_contacts_and_new_directs_but_preserves_history_and_unblock_ownership()
    {
        using var first = await Actor("Consumer"); using var second = await Actor("Producer"); using var third = await Actor("Trader");
        var direct = await Direct(first, second); using var before = await Text(first, direct, "History remains readable"); Assert.Equal(HttpStatusCode.Created, before.StatusCode);
        using var block = await first.Http.PutAsJsonAsync($"/api/v1/profiles/{second.Id}/block", new { }); Assert.Equal(HttpStatusCode.OK, block.StatusCode);
        using var retry = await first.Http.PutAsJsonAsync($"/api/v1/profiles/{second.Id}/block", new { }); Assert.Equal(HttpStatusCode.OK, retry.StatusCode);
        var blocked = await first.Http.GetFromJsonAsync<JsonElement>("/api/v1/profile/blocked"); Assert.Equal(second.Id, Assert.Single(blocked.GetProperty("items").EnumerateArray()).GetProperty("id").GetGuid());
        foreach (var pair in new[] { (first, second), (second, first) })
        {
            using var profile = await pair.Item1.Http.GetAsync($"/api/v1/profiles/{pair.Item2.Id}"); Assert.Equal(HttpStatusCode.NotFound, profile.StatusCode);
            using var newDirect = await pair.Item1.Http.PostAsJsonAsync("/api/v1/conversations/direct", new { userId = pair.Item2.Id }); Assert.Equal(HttpStatusCode.NotFound, newDirect.StatusCode);
            using var send = await Text(pair.Item1, direct, "Blocked new message"); Assert.Equal(HttpStatusCode.Forbidden, send.StatusCode);
            var contacts = await pair.Item1.Http.GetFromJsonAsync<JsonElement>("/api/v1/contacts?limit=50"); Assert.DoesNotContain(contacts.GetProperty("items").EnumerateArray(), row => row.GetProperty("id").GetGuid() == pair.Item2.Id);
            using var history = await pair.Item1.Http.GetAsync($"/api/v1/conversations/{direct}/messages"); Assert.Equal(HttpStatusCode.OK, history.StatusCode);
        }
        using var unauthorizedUnblock = await second.Http.DeleteAsync($"/api/v1/profiles/{first.Id}/block"); Assert.Equal(HttpStatusCode.NoContent, unauthorizedUnblock.StatusCode);
        using var stillDenied = await Text(second, direct, "Still blocked by owner"); Assert.Equal(HttpStatusCode.Forbidden, stillDenied.StatusCode);
        using var outsider = await third.Http.GetAsync($"/api/v1/conversations/{direct}/messages"); Assert.Equal(HttpStatusCode.NotFound, outsider.StatusCode);
        using var self = await first.Http.PutAsJsonAsync($"/api/v1/profiles/{first.Id}/block", new { }); Assert.Equal(HttpStatusCode.BadRequest, self.StatusCode);
        using var unblock = await first.Http.DeleteAsync($"/api/v1/profiles/{second.Id}/block"); Assert.Equal(HttpStatusCode.NoContent, unblock.StatusCode);
        using var after = await Text(second, direct, "Allowed after own block removed"); Assert.Equal(HttpStatusCode.Created, after.StatusCode);
    }

    [Fact]
    public async Task Block_rejects_personal_photo_before_processing_but_does_not_disable_shared_group_writes()
    {
        using var admin = await Actor("Admin"); using var first = await Actor("Consumer"); using var second = await Actor("Producer");
        var direct = await Direct(first, second);
        using var groupResponse = await admin.Http.PostAsJsonAsync("/api/v1/community/groups", new { title = "Profile block shared group fixture", region = "Đồng Tháp" }); Assert.Equal(HttpStatusCode.Created, groupResponse.StatusCode);
        var group = (await groupResponse.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("id").GetGuid();
        foreach (var member in new[] { first, second }) { using var join = await member.Http.PostAsJsonAsync($"/api/v1/community/groups/{group}/join", new { }); Assert.Equal(HttpStatusCode.Created, join.StatusCode); }
        using var block = await first.Http.PutAsJsonAsync($"/api/v1/profiles/{second.Id}/block", new { }); Assert.Equal(HttpStatusCode.OK, block.StatusCode);
        using var image = new ByteArrayContent(Convert.FromBase64String("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=")); image.Headers.ContentType = new("image/png");
        using var denied = await second.Http.PostAsync($"/api/v1/conversations/{direct}/images?clientMessageId={Guid.NewGuid():N}", image); Assert.Equal(HttpStatusCode.Forbidden, denied.StatusCode);
        using var allowed = await Text(second, group, "Shared groups remain available"); Assert.Equal(HttpStatusCode.Created, allowed.StatusCode);
    }

    [Fact]
    public async Task Inflight_direct_send_waits_for_user_lock_and_rechecks_a_newly_committed_block()
    {
        using var first = await Actor("Consumer"); using var second = await Actor("Producer"); var direct = await Direct(first, second);
        using var scope = fixture.Services.CreateScope(); var db = scope.ServiceProvider.GetRequiredService<AppDbContext>(); await using var tx = await db.Database.BeginTransactionAsync();
        await db.Users.FromSqlInterpolated($"SELECT * FROM \"AspNetUsers\" WHERE \"Id\"={first.Id} OR \"Id\"={second.Id} ORDER BY \"Id\" FOR UPDATE").ToListAsync();
        db.Add(new UserBlock { OwnerUserId = first.Id, BlockedUserId = second.Id }); await db.SaveChangesAsync();
        var pending = Text(second, direct, "Must not pass a committed block"); await Task.Delay(100); Assert.False(pending.IsCompleted);
        await tx.CommitAsync(); using var response = await pending.WaitAsync(TimeSpan.FromSeconds(10)); Assert.Equal(HttpStatusCode.Forbidden, response.StatusCode);
        Assert.False(await db.Messages.AnyAsync(m => m.ConversationId == direct));
    }

    private static object Edit(string name, string gender = "Unknown", string? phone = null, bool visible = false) => new { displayName = name, bio = "Common profile fixture", gender, phone, showGender = visible, showPhone = visible, showRegion = visible };
    private static Task<HttpResponseMessage> Text(ActorUser user, Guid conversation, string text) => user.Http.PostAsJsonAsync($"/api/v1/conversations/{conversation}/messages", new { clientMessageId = Guid.NewGuid().ToString("N"), text });
    private static async Task<Guid> Direct(ActorUser first, ActorUser second)
    { using var response = await first.Http.PostAsJsonAsync("/api/v1/conversations/direct", new { userId = second.Id }); Assert.Equal(HttpStatusCode.Created, response.StatusCode); return (await response.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("id").GetGuid(); }
    private async Task<ActorUser> Actor(string role, bool approved = true)
    {
        var user = await TestAccounts.CreateAsync(fixture.Services, fixture.Password, role, approved, "Profile fixture " + Guid.NewGuid().ToString("N"));
        var http = fixture.CreateClient(); using var login = await http.PostAsJsonAsync("/api/v1/auth/login", new { email = user.Email, password = fixture.Password }); Assert.Equal(HttpStatusCode.OK, login.StatusCode);
        http.DefaultRequestHeaders.Authorization = new("Bearer", (await login.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("accessToken").GetString()); return new(user.Id, http);
    }
    private sealed record ActorUser(Guid Id, HttpClient Http) : IDisposable { public void Dispose() => Http.Dispose(); }
}
