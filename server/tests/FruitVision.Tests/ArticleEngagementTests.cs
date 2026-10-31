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
public sealed class ArticleEngagementTests(ApiFixture fixture)
{
    [Fact]
    public async Task Deleted_comment_content_is_erased_and_a_delayed_create_retry_cannot_resurrect_it()
    {
        using var client = fixture.CreateClient(); var user = await Login(client); var article = await Article();
        var key = Guid.NewGuid(); var route = $"/api/v1/articles/{article}/comments";
        using var created = await client.PostAsJsonAsync(route, new { body = "This observation must stay deleted", clientCommentId = key }); Assert.Equal(HttpStatusCode.Created, created.StatusCode);
        var id = (await created.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("id").GetGuid();
        using var deleted = await client.DeleteAsync(route + "/" + id); Assert.Equal(HttpStatusCode.NoContent, deleted.StatusCode);
        using var retry = await client.PostAsJsonAsync(route, new { body = "This observation must stay deleted", clientCommentId = key }); Assert.Equal(HttpStatusCode.Conflict, retry.StatusCode);
        var remaining = await Get(client, route); Assert.Equal(0, remaining.GetProperty("commentCount").GetInt32()); Assert.Empty(remaining.GetProperty("items").EnumerateArray());
        Assert.Equal(0, (await Get(client, $"/api/v1/articles/{article}/likes")).GetProperty("commentCount").GetInt32());
        using var scope = fixture.Services.CreateScope();
        var tombstone = await scope.ServiceProvider.GetRequiredService<AppDbContext>().Set<ArticleComment>().SingleAsync(c => c.ArticleId == article && c.UserId == user.Id && c.ClientCommentId == key);
        Assert.Equal(id, tombstone.Id); Assert.Equal("", tombstone.Body);
    }

    [Fact]
    public async Task Like_is_an_explicit_idempotent_state_and_concurrent_requests_keep_one_durable_row()
    {
        using var reader = fixture.CreateClient(); using var anonymous = fixture.CreateClient();
        var account = await Login(reader); var article = await Article();
        var replies = await Task.WhenAll(Enumerable.Range(0, 4).Select(_ => reader.PutAsJsonAsync($"/api/v1/articles/{article}/like", new { liked = true })));
        try { Assert.All(replies, r => Assert.Equal(HttpStatusCode.OK, r.StatusCode)); }
        finally { foreach (var reply in replies) reply.Dispose(); }
        var own = await Get(reader, $"/api/v1/articles/{article}/likes");
        Assert.Equal(1, own.GetProperty("likeCount").GetInt32()); Assert.True(own.GetProperty("liked").GetBoolean());
        var publicView = await Get(anonymous, $"/api/v1/articles/{article}/likes");
        Assert.Equal(1, publicView.GetProperty("likeCount").GetInt32()); Assert.False(publicView.GetProperty("liked").GetBoolean());
        using (var scope = fixture.Services.CreateScope())
            Assert.Equal(1, await scope.ServiceProvider.GetRequiredService<AppDbContext>().Set<ArticleLike>().CountAsync(l => l.ArticleId == article && l.UserId == account.Id));
        for (var i = 0; i < 2; i++) { using var removed = await reader.PutAsJsonAsync($"/api/v1/articles/{article}/like", new { liked = false }); Assert.Equal(HttpStatusCode.OK, removed.StatusCode); }
        Assert.Equal(0, (await Get(reader, $"/api/v1/articles/{article}/likes")).GetProperty("likeCount").GetInt32());
    }

    [Fact]
    public async Task Comments_retry_once_page_newest_and_expose_only_public_author_identity()
    {
        using var author = fixture.CreateClient(); using var viewer = fixture.CreateClient(); using var admin = fixture.CreateClient();
        var account = await Login(author, "Trader"); await Login(viewer); await Login(admin, "Admin"); var article = await Article();
        var key = Guid.NewGuid(); var route = $"/api/v1/articles/{article}/comments";
        var attempts = await Task.WhenAll(author.PostAsJsonAsync(route, new { body = "An observation about mangoes", clientCommentId = key }), author.PostAsJsonAsync(route, new { body = "An observation about mangoes", clientCommentId = key }));
        JsonElement first;
        try
        {
            Assert.Single(attempts, r => r.StatusCode == HttpStatusCode.Created); Assert.Single(attempts, r => r.StatusCode == HttpStatusCode.OK);
            first = await attempts[0].Content.ReadFromJsonAsync<JsonElement>();
            Assert.Equal(first.GetProperty("id").GetGuid(), (await attempts[1].Content.ReadFromJsonAsync<JsonElement>()).GetProperty("id").GetGuid());
        }
        finally { foreach (var attempt in attempts) attempt.Dispose(); }
        var sender = first.GetProperty("author"); Assert.Equal(account.Id, sender.GetProperty("id").GetGuid()); Assert.Equal("Trader", sender.GetProperty("role").GetString());
        Assert.Equal(new[] { "displayName", "id", "role" }, sender.EnumerateObject().Select(p => p.Name).Order().ToArray());
        using var changed = await author.PostAsJsonAsync(route, new { body = "Changed retry body", clientCommentId = key }); Assert.Equal(HttpStatusCode.Conflict, changed.StatusCode);
        using var next = await viewer.PostAsJsonAsync(route, new { body = "A second observation", clientCommentId = Guid.NewGuid() }); Assert.Equal(HttpStatusCode.Created, next.StatusCode);
        var nextId = (await next.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("id").GetGuid();
        var page = await Get(viewer, route + "?limit=1"); Assert.Equal(2, page.GetProperty("commentCount").GetInt32()); Assert.Equal(nextId, page.GetProperty("items")[0].GetProperty("id").GetGuid());
        var secondPage = await Get(viewer, route + "?limit=1&after=" + page.GetProperty("next").GetGuid()); Assert.Equal(first.GetProperty("id").GetGuid(), secondPage.GetProperty("items")[0].GetProperty("id").GetGuid());
        Assert.False(secondPage.GetProperty("items")[0].GetProperty("canDelete").GetBoolean());
        using var foreignDelete = await viewer.DeleteAsync(route + "/" + first.GetProperty("id").GetGuid()); Assert.Equal(HttpStatusCode.Forbidden, foreignDelete.StatusCode);
        using var ownDelete = await author.DeleteAsync(route + "/" + first.GetProperty("id").GetGuid()); Assert.Equal(HttpStatusCode.NoContent, ownDelete.StatusCode);
        using var adminDelete = await admin.DeleteAsync(route + "/" + nextId); Assert.Equal(HttpStatusCode.NoContent, adminDelete.StatusCode);
        Assert.Equal(0, (await Get(viewer, route)).GetProperty("commentCount").GetInt32());
    }

    [Fact]
    public async Task Pending_anonymous_invalid_and_unknown_inputs_cannot_write_but_four_approved_roles_can()
    {
        using var anonymous = fixture.CreateClient(); using var pending = fixture.CreateClient(); await Login(pending, approve: false); var article = await Article();
        using var unauthenticated = await anonymous.PutAsJsonAsync($"/api/v1/articles/{article}/like", new { liked = true }); Assert.Equal(HttpStatusCode.Unauthorized, unauthenticated.StatusCode);
        foreach (var route in new[] { "like", "comments" })
        { using var denied = route == "like" ? await pending.PutAsJsonAsync($"/api/v1/articles/{article}/like", new { liked = true }) : await pending.PostAsJsonAsync($"/api/v1/articles/{article}/comments", new { body = "Pending comment", clientCommentId = Guid.NewGuid() }); Assert.Equal(HttpStatusCode.Forbidden, denied.StatusCode); }
        foreach (var role in new[] { "Admin", "Producer", "Trader", "Consumer" })
        {
            using var client = fixture.CreateClient(); await Login(client, role);
            using var like = await client.PutAsJsonAsync($"/api/v1/articles/{article}/like", new { liked = true }); Assert.Equal(HttpStatusCode.OK, like.StatusCode);
            using var comment = await client.PostAsJsonAsync($"/api/v1/articles/{article}/comments", new { body = "Approved observation", clientCommentId = Guid.NewGuid() }); Assert.Equal(HttpStatusCode.Created, comment.StatusCode);
            using var injected = await client.PutAsJsonAsync($"/api/v1/articles/{article}/like", new { liked = true, userId = Guid.NewGuid() }); Assert.Equal(HttpStatusCode.BadRequest, injected.StatusCode);
            using var missing = await client.PostAsJsonAsync($"/api/v1/articles/{article}/comments", new { body = "Missing idempotency ID" }); Assert.Equal(HttpStatusCode.BadRequest, missing.StatusCode);
            using var invalid = await client.PostAsJsonAsync($"/api/v1/articles/{article}/comments", new { body = "bad\0text", clientCommentId = Guid.NewGuid() }); Assert.Equal(HttpStatusCode.BadRequest, invalid.StatusCode);
        }
    }

    [Fact]
    public async Task Engagement_becomes_unreadable_and_unwritable_when_article_author_or_branch_is_hidden()
    {
        using var client = fixture.CreateClient(); await Login(client);
        foreach (var state in new[] { "AwaitingReview", "Paused", "InactiveAuthor", "PendingAuthor", "UnapprovedBranch" })
        {
            var article = await Article(state);
            using var likes = await client.GetAsync($"/api/v1/articles/{article}/likes"); using var comments = await client.GetAsync($"/api/v1/articles/{article}/comments");
            using var like = await client.PutAsJsonAsync($"/api/v1/articles/{article}/like", new { liked = true });
            using var comment = await client.PostAsJsonAsync($"/api/v1/articles/{article}/comments", new { body = "Should stay hidden", clientCommentId = Guid.NewGuid() });
            Assert.All(new[] { likes, comments, like, comment }, response => Assert.Equal(HttpStatusCode.NotFound, response.StatusCode));
        }
        var published = await Article(); using var made = await client.PostAsJsonAsync($"/api/v1/articles/{published}/comments", new { body = "Visible before withdrawal", clientCommentId = Guid.NewGuid() }); Assert.Equal(HttpStatusCode.Created, made.StatusCode);
        var id = (await made.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("id").GetGuid();
        using (var scope = fixture.Services.CreateScope()) { var db = scope.ServiceProvider.GetRequiredService<AppDbContext>(); var row = await db.Set<CommunityArticle>().SingleAsync(a => a.Id == published); row.Status = "Paused"; await db.SaveChangesAsync(); }
        using var hiddenDelete = await client.DeleteAsync($"/api/v1/articles/{published}/comments/{id}"); Assert.Equal(HttpStatusCode.NotFound, hiddenDelete.StatusCode);
    }

    private async Task<TestAccount> Login(HttpClient client, string role = "Consumer", bool approve = true)
    {
        var user = await TestAccounts.CreateAsync(fixture.Services, fixture.Password, role, approve, "Engagement tester");
        using var login = await client.PostAsJsonAsync("/api/v1/auth/login", new { email = user.Email, password = fixture.Password }); Assert.Equal(HttpStatusCode.OK, login.StatusCode);
        client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", (await login.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("accessToken").GetString()); return user;
    }
    private async Task<Guid> Article(string state = "Published")
    {
        var author = await TestAccounts.CreateAsync(fixture.Services, fixture.Password, state == "UnapprovedBranch" ? "Producer" : "Consumer");
        using var scope = fixture.Services.CreateScope(); var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
        var user = await db.Users.SingleAsync(u => u.Id == author.Id);
        if (state == "InactiveAuthor") user.IsActive = false; if (state == "PendingAuthor") user.ApprovalStatus = ApprovalState.Pending;
        if (state == "UnapprovedBranch") (await db.Set<SellerBranch>().SingleAsync(b => b.Id == author.BranchId)).Status = "Rejected";
        var article = new CommunityArticle { AuthorId = user.Id, Title = "Article for engagement", Body = "Published public observation for the integration fixture.", Status = state is "AwaitingReview" or "Paused" ? state : "Published", AudienceLane = author.BranchId.HasValue ? "Professional" : "Community", BranchId = author.BranchId };
        db.Add(article); await db.SaveChangesAsync(); return article.Id;
    }
    private static async Task<JsonElement> Get(HttpClient client, string path)
    { using var response = await client.GetAsync(path); Assert.Equal(HttpStatusCode.OK, response.StatusCode); return await response.Content.ReadFromJsonAsync<JsonElement>(); }
}
