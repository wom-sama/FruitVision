using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text.Json;
using FruitVision.Api.Data;
using Microsoft.AspNetCore.Identity;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
using Xunit;

namespace FruitVision.Tests;

[Collection("Api")]
public sealed class PublishingCrudTests(ApiFixture fixture)
{
    [Fact]
    public async Task Own_article_CRUD_hides_deleted_content_but_preserves_existing_conversation_and_audit()
    {
        using var owner = await Actor("Consumer"); using var reader = await Actor("Consumer"); using var admin = await Actor("Admin");
        var article = await Json(owner.Http, HttpMethod.Post, "/api/v1/articles", new { title = "CRUD community observations", body = "A useful account of mango skin observations for community readers." });
        var id = article.GetProperty("id").GetGuid();
        await Json(owner.Http, HttpMethod.Put, $"/api/v1/articles/{id}", new { title = "Updated mango observations", body = "The revised observations must be reviewed before publication.", expectedRevision = 1 });
        await Json(admin.Http, HttpMethod.Post, $"/api/v1/admin/articles/{id}/review", new { status = "Published", reason = "CRUD test publication", expectedRevision = 2 });
        var thread = await Json(reader.Http, HttpMethod.Post, $"/api/v1/articles/{id}/conversations", new { });
        var threadId = thread.GetProperty("id").GetGuid();
        using var stale = await owner.Http.DeleteAsync($"/api/v1/articles/{id}?expectedRevision=2"); Assert.Equal(HttpStatusCode.Conflict, stale.StatusCode);
        using var foreign = await reader.Http.DeleteAsync($"/api/v1/articles/{id}?expectedRevision=3"); Assert.Equal(HttpStatusCode.NotFound, foreign.StatusCode);
        using var deleted = await owner.Http.DeleteAsync($"/api/v1/articles/{id}?expectedRevision=3"); Assert.Equal(HttpStatusCode.NoContent, deleted.StatusCode);
        using var repeated = await owner.Http.DeleteAsync($"/api/v1/articles/{id}?expectedRevision=3"); Assert.Equal(HttpStatusCode.NoContent, repeated.StatusCode);
        foreach (var path in new[] { $"/api/v1/articles/{id}", $"/api/v1/articles/{id}/likes", $"/api/v1/articles/{id}/comments" })
        { using var response = await owner.Http.GetAsync(path); Assert.Equal(HttpStatusCode.NotFound, response.StatusCode); }
        var mine = await Json(owner.Http, HttpMethod.Get, "/api/v1/articles/mine"); Assert.DoesNotContain(mine.GetProperty("items").EnumerateArray(), item => item.GetProperty("id").GetGuid() == id);
        using var revive = await owner.Http.PutAsJsonAsync($"/api/v1/articles/{id}", new { title = "Cannot revive deleted article", body = "A deleted article must never be silently restored by edit.", expectedRevision = 4 }); Assert.Equal(HttpStatusCode.NotFound, revive.StatusCode);
        using var review = await admin.Http.PostAsJsonAsync($"/api/v1/admin/articles/{id}/review", new { status = "Published", reason = "Cannot restore deletion", expectedRevision = 4 }); Assert.Equal(HttpStatusCode.NotFound, review.StatusCode);
        using var newContact = await reader.Http.PostAsJsonAsync($"/api/v1/articles/{id}/conversations", new { }); Assert.Equal(HttpStatusCode.NotFound, newContact.StatusCode);
        using var messages = await reader.Http.GetAsync($"/api/v1/conversations/{threadId}/messages"); Assert.Equal(HttpStatusCode.OK, messages.StatusCode);
        using var scope = fixture.Services.CreateScope(); var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
        var saved = await db.Set<CommunityArticle>().SingleAsync(a => a.Id == id); Assert.Equal("Deleted", saved.Status); Assert.Equal(4, saved.Revision);
        Assert.Single(await db.AuditEntries.Where(a => a.SubjectId == owner.Id && a.Action == "ArticleDeleted" && a.Reason == id.ToString()).ToListAsync());
        Assert.True(await db.Conversations.AnyAsync(c => c.Id == threadId));
    }

    [Fact]
    public async Task Branch_delete_requires_owner_revision_and_no_remaining_linked_content()
    {
        using var owner = await Actor("Producer"); using var outsider = await Actor("Trader"); using var admin = await Actor("Admin");
        var branch = new SellerBranch { OwnerId = owner.Id, Name = "CRUD production site", CountryCode = "VN", ProvinceCode = "01", CountryName = "Việt Nam", ProvinceName = "Hà Nội", Region = "Hà Nội, Việt Nam", Street = "123 production street", Phone = "0901234567", Status = "Approved" };
        var linked = new CommunityArticle { AuthorId = owner.Id, BranchId = branch.Id, AudienceLane = "Professional", Title = "Linked production article", Body = "This professional article still depends on the approved production site." };
        using (var scope = fixture.Services.CreateScope()) { var db = scope.ServiceProvider.GetRequiredService<AppDbContext>(); db.AddRange(branch, linked); await db.SaveChangesAsync(); }
        using var foreign = await outsider.Http.DeleteAsync($"/api/v1/branches/{branch.Id}?expectedRevision=1"); Assert.Equal(HttpStatusCode.NotFound, foreign.StatusCode);
        using var linkedResponse = await owner.Http.DeleteAsync($"/api/v1/branches/{branch.Id}?expectedRevision=1"); Assert.Equal(HttpStatusCode.Conflict, linkedResponse.StatusCode);
        using var articleDelete = await owner.Http.DeleteAsync($"/api/v1/articles/{linked.Id}?expectedRevision=1"); Assert.Equal(HttpStatusCode.NoContent, articleDelete.StatusCode);
        using var stale = await owner.Http.DeleteAsync($"/api/v1/branches/{branch.Id}?expectedRevision=2"); Assert.Equal(HttpStatusCode.Conflict, stale.StatusCode);
        using var deleted = await owner.Http.DeleteAsync($"/api/v1/branches/{branch.Id}?expectedRevision=1"); Assert.Equal(HttpStatusCode.NoContent, deleted.StatusCode);
        using var repeated = await owner.Http.DeleteAsync($"/api/v1/branches/{branch.Id}?expectedRevision=1"); Assert.Equal(HttpStatusCode.NoContent, repeated.StatusCode);
        using var hidden = await owner.Http.GetAsync($"/api/v1/branches/{branch.Id}"); Assert.Equal(HttpStatusCode.NotFound, hidden.StatusCode);
        var mine = await Json(owner.Http, HttpMethod.Get, "/api/v1/branches/mine"); Assert.DoesNotContain(mine.GetProperty("items").EnumerateArray(), item => item.GetProperty("id").GetGuid() == branch.Id);
        using var edit = await owner.Http.PutAsJsonAsync($"/api/v1/branches/{branch.Id}", new { name = "Cannot restore deleted branch", countryCode = "VN", provinceCode = "01", street = "123 production street", phone = "0901234567", expectedRevision = 2 }); Assert.Equal(HttpStatusCode.NotFound, edit.StatusCode);
        using var review = await admin.Http.PostAsJsonAsync($"/api/v1/admin/branches/{branch.Id}/review", new { status = "Approved", reason = "Cannot restore deleted branch", expectedRevision = 2 }); Assert.Equal(HttpStatusCode.NotFound, review.StatusCode);
        using var scope2 = fixture.Services.CreateScope(); var saved = await scope2.ServiceProvider.GetRequiredService<AppDbContext>().Set<SellerBranch>().SingleAsync(b => b.Id == branch.Id); Assert.Equal("Deleted", saved.Status); Assert.Equal(2, saved.Revision);
    }

    [Fact]
    public async Task Delete_requires_authenticated_current_owner_and_explicit_valid_revision()
    {
        using var owner = await Actor("Consumer"); using var admin = await Actor("Admin"); using var anonymous = fixture.CreateClient();
        var id = (await Json(owner.Http, HttpMethod.Post, "/api/v1/articles", new { title = "Revision required delete", body = "Delete must have an explicit positive revision to avoid stale actions." })).GetProperty("id").GetGuid();
        using var noAuth = await anonymous.DeleteAsync($"/api/v1/articles/{id}?expectedRevision=1"); Assert.Equal(HttpStatusCode.Unauthorized, noAuth.StatusCode);
        using var noRevision = await owner.Http.DeleteAsync($"/api/v1/articles/{id}"); Assert.Equal(HttpStatusCode.BadRequest, noRevision.StatusCode);
        using var invalid = await owner.Http.DeleteAsync($"/api/v1/articles/{id}?expectedRevision=0"); Assert.Equal(HttpStatusCode.BadRequest, invalid.StatusCode);
        using var privileged = await admin.Http.DeleteAsync($"/api/v1/articles/{id}?expectedRevision=1"); Assert.Equal(HttpStatusCode.Forbidden, privileged.StatusCode);
    }

    private async Task<ActorClient> Actor(string role)
    {
        var email = $"crud-{Guid.NewGuid():N}@example.test"; var id = Guid.NewGuid();
        using (var scope = fixture.Services.CreateScope())
        {
            var manager = scope.ServiceProvider.GetRequiredService<UserManager<AppUser>>();
            Assert.True((await manager.CreateAsync(new AppUser { Id = id, UserName = email, Email = email, EmailConfirmed = true, DisplayName = "CRUD fixture " + role, Region = "Test", Role = Enum.Parse<AccountRole>(role), ApprovalStatus = ApprovalState.Approved, IsActive = true }, fixture.Password)).Succeeded);
        }
        var http = fixture.CreateClient(); var token = await Json(http, HttpMethod.Post, "/api/v1/auth/login", new { email, password = fixture.Password });
        http.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", token.GetProperty("accessToken").GetString()); return new ActorClient(id, http);
    }
    private static async Task<JsonElement> Json(HttpClient client, HttpMethod method, string path, object? body = null)
    { using var request = new HttpRequestMessage(method, path) { Content = body is null ? null : JsonContent.Create(body) }; using var response = await client.SendAsync(request); Assert.True(response.IsSuccessStatusCode, $"{method} {path}: {response.StatusCode}"); return await response.Content.ReadFromJsonAsync<JsonElement>(); }
    private sealed record ActorClient(Guid Id, HttpClient Http) : IDisposable { public void Dispose() => Http.Dispose(); }
}
