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
public sealed class DirectContactsTests(ApiFixture fixture)
{
    [Fact]
    public async Task Contact_search_returns_only_other_active_approved_public_identities_and_bounds_input()
    {
        var tag = "Contacts" + Guid.NewGuid().ToString("N");
        using var owner = await Actor("Consumer", tag + " Owner"); using var peer = await Actor("Admin", tag + " Peer");
        using var pending = await Actor("Trader", tag + " Pending", false); using var inactive = await Actor("Producer", tag + " Inactive");
        using (var scope = fixture.Services.CreateScope()) await scope.ServiceProvider.GetRequiredService<AppDbContext>().Users.Where(u => u.Id == inactive.Id).ExecuteUpdateAsync(set => set.SetProperty(u => u.IsActive, false));
        using var response = await owner.Http.GetAsync("/api/v1/contacts?search=" + tag.ToLowerInvariant() + "&limit=20"); Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        var items = (await response.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("items").EnumerateArray().ToArray(); Assert.Single(items);
        Assert.Equal(peer.Id, items[0].GetProperty("id").GetGuid()); Assert.Equal("Admin", items[0].GetProperty("role").GetString());
        Assert.Equal(new[] { "displayName", "id", "role" }, items[0].EnumerateObject().Select(p => p.Name).Order().ToArray());
        using var tooLong = await owner.Http.GetAsync("/api/v1/contacts?search=" + new string('x', 81)); Assert.Equal(HttpStatusCode.BadRequest, tooLong.StatusCode);
        using var badLimit = await owner.Http.GetAsync("/api/v1/contacts?limit=51"); Assert.Equal(HttpStatusCode.BadRequest, badLimit.StatusCode);
        using var notApproved = await pending.Http.GetAsync("/api/v1/contacts"); Assert.Equal(HttpStatusCode.Forbidden, notApproved.StatusCode);
        using var anonymous = fixture.CreateClient(); using var noLogin = await anonymous.GetAsync("/api/v1/contacts"); Assert.Equal(HttpStatusCode.Unauthorized, noLogin.StatusCode);
    }

    [Fact]
    public async Task Opposite_side_concurrent_generic_direct_requests_create_exactly_one_two_member_thread()
    {
        using var consumer = await Actor("Consumer", "Generic Consumer fixture"); using var admin = await Actor("Admin", "Generic Admin fixture");
        var replies = await Task.WhenAll(Enumerable.Range(0, 6).Select(i => i % 2 == 0 ? Send(consumer.Http, admin.Id) : Send(admin.Http, consumer.Id)));
        Guid id;
        try
        {
            Assert.Single(replies, r => r.StatusCode == HttpStatusCode.Created); Assert.Equal(5, replies.Count(r => r.StatusCode == HttpStatusCode.OK));
            var values = await Task.WhenAll(replies.Select(r => r.Content.ReadFromJsonAsync<JsonElement>())); Assert.Single(values.Select(v => v.GetProperty("id").GetGuid()).Distinct());
            id = values[0].GetProperty("id").GetGuid(); Assert.Equal("Direct", values[0].GetProperty("kind").GetString());
            Assert.Equal(JsonValueKind.Null, values[0].GetProperty("postId").ValueKind); Assert.Equal(JsonValueKind.Null, values[0].GetProperty("articleId").ValueKind);
        }
        finally { foreach (var reply in replies) reply.Dispose(); }
        using var scope = fixture.Services.CreateScope(); var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
        Assert.Equal(new[] { consumer.Id, admin.Id }.Order(), (await db.Participants.Where(p => p.ConversationId == id).Select(p => p.UserId).ToArrayAsync()).Order());
        Assert.Equal(1, await db.Conversations.CountAsync(c => c.Id == id));
    }

    [Fact]
    public async Task Self_missing_ineligible_and_caller_assigned_participants_are_rejected()
    {
        using var owner = await Actor("Producer", "Direct owner fixture"); using var pending = await Actor("Consumer", "Pending direct fixture", false);
        using var self = await Send(owner.Http, owner.Id); Assert.Equal(HttpStatusCode.BadRequest, self.StatusCode);
        using var missing = await Send(owner.Http, Guid.NewGuid()); Assert.Equal(HttpStatusCode.NotFound, missing.StatusCode);
        using var denied = await Send(owner.Http, pending.Id); Assert.Equal(HttpStatusCode.NotFound, denied.StatusCode);
        using var injection = await owner.Http.PostAsJsonAsync("/api/v1/conversations/direct", new { userId = pending.Id, participants = new[] { owner.Id, pending.Id } }); Assert.Equal(HttpStatusCode.BadRequest, injection.StatusCode);
        using var empty = await Send(owner.Http, Guid.Empty); Assert.Equal(HttpStatusCode.BadRequest, empty.StatusCode);
        using var notApproved = await Send(pending.Http, owner.Id); Assert.Equal(HttpStatusCode.Forbidden, notApproved.StatusCode);
    }

    [Fact]
    public async Task Generic_direct_never_reuses_article_or_group_context_and_outsider_cannot_read_it()
    {
        using var first = await Actor("Producer", "Generic first fixture"); using var second = await Actor("Trader", "Generic second fixture"); using var outsider = await Actor("Consumer", "Generic outsider fixture");
        Guid articleThread;
        using (var scope = fixture.Services.CreateScope())
        {
            var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
            var article = new CommunityArticle { AuthorId = outsider.Id, Title = "Declared test community context", Body = "Test fixture only, no trading or quantity claims." }; db.Add(article);
            var old = new Conversation { Title = "Old article context fixture", Kind = "Direct", ArticleId = article.Id, OwnerId = first.Id, InitiatorId = second.Id }; articleThread = old.Id;
            db.Conversations.Add(old); db.Participants.AddRange(new Participant { ConversationId = old.Id, UserId = first.Id }, new Participant { ConversationId = old.Id, UserId = second.Id }); await db.SaveChangesAsync();
        }
        using var created = await Send(first.Http, second.Id); Assert.Equal(HttpStatusCode.Created, created.StatusCode);
        var id = (await created.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("id").GetGuid(); Assert.NotEqual(articleThread, id);
        using var retry = await Send(second.Http, first.Id); Assert.Equal(HttpStatusCode.OK, retry.StatusCode); Assert.Equal(id, (await retry.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("id").GetGuid());
        using var hidden = await outsider.Http.GetAsync($"/api/v1/conversations/{id}/messages"); Assert.Equal(HttpStatusCode.NotFound, hidden.StatusCode);
        using var context = await first.Http.GetAsync($"/api/v1/conversations/{id}/context"); Assert.Equal(HttpStatusCode.OK, context.StatusCode);
        Assert.True((await context.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("secretEligible").GetBoolean());
    }

    private async Task<User> Actor(string role, string displayName, bool approved = true)
    {
        var account = await TestAccounts.CreateAsync(fixture.Services, fixture.Password, role, approved, displayName);
        var http = fixture.CreateClient(); using var login = await http.PostAsJsonAsync("/api/v1/auth/login", new { email = account.Email, password = fixture.Password }); Assert.Equal(HttpStatusCode.OK, login.StatusCode);
        http.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", (await login.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("accessToken").GetString()); return new(account.Id, http);
    }
    private static Task<HttpResponseMessage> Send(HttpClient client, Guid userId) => client.PostAsJsonAsync("/api/v1/conversations/direct", new { userId });
    private sealed record User(Guid Id, HttpClient Http) : IDisposable { public void Dispose() => Http.Dispose(); }
}
