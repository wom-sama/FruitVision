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
public sealed class ArticleContactTests(ApiFixture fixture)
{
    [Fact]
    public async Task Concurrent_article_contacts_create_one_private_direct_thread_and_keep_article_context()
    {
        using var author = await Actor("Producer"); using var peer = await Actor("Producer");
        using var consumer = await Actor("Consumer"); using var admin = await Actor("Admin");
        var articleId = await Publish(author, admin); var requests = await Task.WhenAll(Enumerable.Range(0, 6)
            .Select(_ => peer.Http.PostAsJsonAsync($"/api/v1/articles/{articleId}/conversations", new { })));
        JsonElement thread;
        try
        {
            Assert.Single(requests, r => r.StatusCode == HttpStatusCode.Created);
            Assert.Equal(5, requests.Count(r => r.StatusCode == HttpStatusCode.OK));
            var rows = await Task.WhenAll(requests.Select(r => r.Content.ReadFromJsonAsync<JsonElement>()));
            Assert.Single(rows.Select(r => r.GetProperty("id").GetGuid()).Distinct()); thread = rows[0];
        }
        finally { foreach (var response in requests) response.Dispose(); }
        var id = thread.GetProperty("id").GetGuid();
        Assert.Equal(articleId, thread.GetProperty("articleId").GetGuid());
        Assert.Equal(JsonValueKind.Null, thread.GetProperty("postId").ValueKind);
        Assert.Equal("Direct", thread.GetProperty("kind").GetString());
        using var another = await consumer.Http.PostAsJsonAsync($"/api/v1/articles/{articleId}/conversations", new { });
        Assert.Equal(HttpStatusCode.Created, another.StatusCode);
        Assert.NotEqual(id, (await another.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("id").GetGuid());
        using var scope = fixture.Services.CreateScope(); var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
        var members = await db.Participants.Where(p => p.ConversationId == id).Select(p => p.UserId).ToArrayAsync();
        Assert.Equal(new[] { author.Id, peer.Id }.Order(), members.Order());
        Assert.Equal(1, await db.Conversations.CountAsync(c => c.ArticleId == articleId && c.InitiatorId == peer.Id));
        Assert.Equal(1, await db.AuditEntries.CountAsync(a => a.Action == "ArticleContactCreated" && a.Reason == id.ToString()));
        Assert.Equal(2, await db.InteractionHistories.CountAsync(h => h.Kind == "ConversationCreated" && h.Body.Contains(id.ToString())));
        using var message = await peer.Http.PostAsJsonAsync($"/api/v1/conversations/{id}/messages", new { text = "A mango knowledge question from a peer.", clientMessageId = Guid.NewGuid().ToString("N") });
        Assert.Equal(HttpStatusCode.Created, message.StatusCode);
        using var privateMessages = await consumer.Http.GetAsync($"/api/v1/conversations/{id}/messages");
        Assert.Equal(HttpStatusCode.NotFound, privateMessages.StatusCode);
    }

    [Fact]
    public async Task Contact_rejects_admin_self_unapproved_hidden_and_revoked_professional_branch()
    {
        using var author = await Actor("Trader"); using var reader = await Actor("Consumer");
        using var admin = await Actor("Admin"); using var pending = await Actor("Consumer", approved: false);
        using var anonymous = fixture.CreateClient(); var articleId = await Publish(author, admin);
        using var noLogin = await anonymous.PostAsJsonAsync($"/api/v1/articles/{articleId}/conversations", new { }); Assert.Equal(HttpStatusCode.Unauthorized, noLogin.StatusCode);
        using var noApproval = await pending.Http.PostAsJsonAsync($"/api/v1/articles/{articleId}/conversations", new { }); Assert.Equal(HttpStatusCode.Forbidden, noApproval.StatusCode);
        using var noAdmin = await admin.Http.PostAsJsonAsync($"/api/v1/articles/{articleId}/conversations", new { }); Assert.Equal(HttpStatusCode.Forbidden, noAdmin.StatusCode);
        using var self = await author.Http.PostAsJsonAsync($"/api/v1/articles/{articleId}/conversations", new { }); Assert.Equal(HttpStatusCode.Conflict, self.StatusCode);
        using var callerMember = await reader.Http.PostAsJsonAsync($"/api/v1/articles/{articleId}/conversations", new { authorId = reader.Id }); Assert.Equal(HttpStatusCode.BadRequest, callerMember.StatusCode);
        using var created = await reader.Http.PostAsJsonAsync($"/api/v1/articles/{articleId}/conversations", new { }); Assert.Equal(HttpStatusCode.Created, created.StatusCode);
        using (var scope = fixture.Services.CreateScope())
            await scope.ServiceProvider.GetRequiredService<AppDbContext>().Set<SellerBranch>().Where(b => b.Id == author.BranchId).ExecuteUpdateAsync(set => set.SetProperty(b => b.Status, "NeedsInformation"));
        using var revoked = await reader.Http.PostAsJsonAsync($"/api/v1/articles/{articleId}/conversations", new { }); Assert.Equal(HttpStatusCode.NotFound, revoked.StatusCode);
        using var hidden = await reader.Http.PostAsJsonAsync($"/api/v1/articles/{Guid.NewGuid()}/conversations", new { }); Assert.Equal(HttpStatusCode.NotFound, hidden.StatusCode);
        using var draft = await reader.Http.PostAsJsonAsync("/api/v1/articles", new { title = "Unreviewed community mango notes", body = "Not yet reviewed, so no reader can open a new conversation." });
        Assert.Equal(HttpStatusCode.Created, draft.StatusCode);
        var draftId = (await draft.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("id").GetGuid();
        using var unreviewed = await author.Http.PostAsJsonAsync($"/api/v1/articles/{draftId}/conversations", new { }); Assert.Equal(HttpStatusCode.NotFound, unreviewed.StatusCode);
    }

    [Fact]
    public async Task Community_contact_is_available_but_never_repairs_arbitrary_or_missing_members()
    {
        using var author = await Actor("Consumer"); using var reader = await Actor("Consumer");
        using var other = await Actor("Trader"); using var admin = await Actor("Admin");
        var articleId = await Publish(author, admin);
        using var created = await reader.Http.PostAsJsonAsync($"/api/v1/articles/{articleId}/conversations", new { }); Assert.Equal(HttpStatusCode.Created, created.StatusCode);
        var id = (await created.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("id").GetGuid();
        using (var scope = fixture.Services.CreateScope())
        {
            var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
            await db.Participants.Where(p => p.ConversationId == id && p.UserId == reader.Id).ExecuteDeleteAsync();
            db.Participants.Add(new Participant { ConversationId = id, UserId = other.Id }); await db.SaveChangesAsync();
        }
        using var removedMember = await reader.Http.PostAsJsonAsync($"/api/v1/articles/{articleId}/conversations", new { }); Assert.Equal(HttpStatusCode.NotFound, removedMember.StatusCode);
        using var read = await reader.Http.GetAsync($"/api/v1/conversations/{id}/messages"); Assert.Equal(HttpStatusCode.NotFound, read.StatusCode);
        using var paused = await admin.Http.PostAsJsonAsync($"/api/v1/admin/articles/{articleId}/review", new { status = "Paused", reason = "Declared test visibility pause", expectedRevision = 2 }); Assert.Equal(HttpStatusCode.OK, paused.StatusCode);
        using var stale = await other.Http.PostAsJsonAsync($"/api/v1/articles/{articleId}/conversations", new { }); Assert.Equal(HttpStatusCode.NotFound, stale.StatusCode);
    }

    private async Task<User> Actor(string role, bool approved = true)
    {
        var account = await TestAccounts.CreateAsync(fixture.Services, fixture.Password, role, approved, "Article contact fixture");
        var http = fixture.CreateClient(); using var login = await http.PostAsJsonAsync("/api/v1/auth/login", new { email = account.Email, password = fixture.Password }); Assert.Equal(HttpStatusCode.OK, login.StatusCode);
        http.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", (await login.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("accessToken").GetString());
        return new(account.Id, account.BranchId, http);
    }
    private static async Task<Guid> Publish(User author, User admin)
    {
        using var submitted = await author.Http.PostAsJsonAsync("/api/v1/articles", new { title = "Mango knowledge test article", body = "A declared test observation about mango, without transaction or quantity claims.", branchId = author.BranchId }); Assert.Equal(HttpStatusCode.Created, submitted.StatusCode);
        var id = (await submitted.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("id").GetGuid();
        using var reviewed = await admin.Http.PostAsJsonAsync($"/api/v1/admin/articles/{id}/review", new { status = "Published", reason = "Declared test moderation", expectedRevision = 1 }); Assert.Equal(HttpStatusCode.OK, reviewed.StatusCode);
        return id;
    }
    private sealed record User(Guid Id, Guid? BranchId, HttpClient Http) : IDisposable { public void Dispose() => Http.Dispose(); }
}
