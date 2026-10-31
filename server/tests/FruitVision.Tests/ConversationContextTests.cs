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
public sealed class ConversationContextTests(ApiFixture fixture)
{
    [Fact]
    public async Task Two_sellers_receive_only_the_other_public_identity_and_secret_eligibility()
    {
        using var producer = await Actor("Producer"); using var trader = await Actor("Trader");
        var id = await Thread("Direct", producer.Id, trader.Id);
        var value = await Context(producer.Http, id);
        Assert.Equal(new[] { "kind", "peer", "secretEligible", "title" }, value.EnumerateObject().Select(p => p.Name).Order().ToArray());
        Assert.Equal("Direct", value.GetProperty("kind").GetString()); Assert.True(value.GetProperty("secretEligible").GetBoolean());
        var peer = value.GetProperty("peer");
        Assert.Equal(new[] { "displayName", "id", "role" }, peer.EnumerateObject().Select(p => p.Name).Order().ToArray());
        Assert.Equal(trader.Id, peer.GetProperty("id").GetGuid()); Assert.Equal("Trader", peer.GetProperty("role").GetString());
        Assert.Equal("Context Trader", peer.GetProperty("displayName").GetString());
        Assert.Equal(producer.Id, (await Context(trader.Http, id)).GetProperty("peer").GetProperty("id").GetGuid());
        Assert.DoesNotContain("email", value.GetRawText(), StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("key", value.GetRawText(), StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public async Task Consumer_or_inactive_or_unapproved_partner_never_enables_secret_mode()
    {
        using var producer = await Actor("Producer"); using var consumer = await Actor("Consumer");
        var id = await Thread("Direct", producer.Id, consumer.Id);
        var normal = await Context(producer.Http, id); Assert.False(normal.GetProperty("secretEligible").GetBoolean());
        Assert.Equal("Consumer", normal.GetProperty("peer").GetProperty("role").GetString());
        using var scope = fixture.Services.CreateScope(); var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
        await db.Users.Where(u => u.Id == consumer.Id).ExecuteUpdateAsync(set => set.SetProperty(u => u.Role, AccountRole.Trader).SetProperty(u => u.IsActive, false));
        Assert.False((await Context(producer.Http, id)).GetProperty("secretEligible").GetBoolean());
        await db.Users.Where(u => u.Id == consumer.Id).ExecuteUpdateAsync(set => set.SetProperty(u => u.IsActive, true).SetProperty(u => u.ApprovalStatus, ApprovalState.NeedsInformation));
        Assert.False((await Context(producer.Http, id)).GetProperty("secretEligible").GetBoolean());
    }

    [Fact]
    public async Task Group_returns_no_peer_and_no_secret_while_outsiders_and_unapproved_users_are_denied()
    {
        using var producer = await Actor("Producer"); using var trader = await Actor("Trader"); using var admin = await Actor("Admin");
        using var pending = await Actor("Consumer", approved: false); using var anonymous = fixture.CreateClient();
        var id = await Thread("Group", producer.Id, trader.Id, pending.Id);
        var group = await Context(producer.Http, id); Assert.Equal("Group", group.GetProperty("kind").GetString());
        Assert.Equal(JsonValueKind.Null, group.GetProperty("peer").ValueKind); Assert.False(group.GetProperty("secretEligible").GetBoolean());
        using var outsider = await admin.Http.GetAsync($"/api/v1/conversations/{id}/context"); Assert.Equal(HttpStatusCode.NotFound, outsider.StatusCode);
        using var noApproval = await pending.Http.GetAsync($"/api/v1/conversations/{id}/context"); Assert.Equal(HttpStatusCode.Forbidden, noApproval.StatusCode);
        using var noLogin = await anonymous.GetAsync($"/api/v1/conversations/{id}/context"); Assert.Equal(HttpStatusCode.Unauthorized, noLogin.StatusCode);
    }

    [Fact]
    public async Task Malformed_direct_membership_and_removed_member_are_not_exposed_or_repaired()
    {
        using var producer = await Actor("Producer"); using var trader = await Actor("Trader"); using var consumer = await Actor("Consumer");
        var three = await Thread("Direct", producer.Id, trader.Id, consumer.Id);
        using var malformed = await producer.Http.GetAsync($"/api/v1/conversations/{three}/context"); Assert.Equal(HttpStatusCode.NotFound, malformed.StatusCode);
        var id = await Thread("Direct", producer.Id, trader.Id);
        using var scope = fixture.Services.CreateScope(); var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
        await db.Participants.Where(p => p.ConversationId == id && p.UserId == trader.Id).ExecuteDeleteAsync();
        using var removed = await trader.Http.GetAsync($"/api/v1/conversations/{id}/context"); Assert.Equal(HttpStatusCode.NotFound, removed.StatusCode);
        using var incomplete = await producer.Http.GetAsync($"/api/v1/conversations/{id}/context"); Assert.Equal(HttpStatusCode.NotFound, incomplete.StatusCode);
        Assert.Equal(1, await db.Participants.CountAsync(p => p.ConversationId == id));
    }

    private async Task<User> Actor(string role, bool approved = true)
    {
        var account = await TestAccounts.CreateAsync(fixture.Services, fixture.Password, role, approved, "Context " + role);
        var http = fixture.CreateClient(); using var login = await http.PostAsJsonAsync("/api/v1/auth/login", new { email = account.Email, password = fixture.Password }); Assert.Equal(HttpStatusCode.OK, login.StatusCode);
        http.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", (await login.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("accessToken").GetString());
        return new(account.Id, http);
    }
    private async Task<Guid> Thread(string kind, params Guid[] members)
    {
        using var scope = fixture.Services.CreateScope(); var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
        var conversation = new Conversation { Kind = kind, Title = "Declared conversation context fixture", OwnerId = members[0] };
        db.Conversations.Add(conversation); db.Participants.AddRange(members.Select(uid => new Participant { ConversationId = conversation.Id, UserId = uid }));
        await db.SaveChangesAsync(); return conversation.Id;
    }
    private static async Task<JsonElement> Context(HttpClient client, Guid id)
    { using var response = await client.GetAsync($"/api/v1/conversations/{id}/context"); Assert.Equal(HttpStatusCode.OK, response.StatusCode); return await response.Content.ReadFromJsonAsync<JsonElement>(); }
    private sealed record User(Guid Id, HttpClient Http) : IDisposable { public void Dispose() => Http.Dispose(); }
}
