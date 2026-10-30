using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text;
using System.Text.Json;
using FruitVision.Api.Data;
using FruitVision.Api.Features;
using FruitVision.Api.Infrastructure;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Identity;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
using Xunit;

namespace FruitVision.Tests;

[Collection("Api")]
public sealed class PublishingTests(ApiFixture fixture)
{
    [Fact]
    public async Task Consumer_articles_are_a_separate_reviewed_plain_text_lane()
    {
        using var app = App(); using var consumer = await Account(app, "Consumer");
        using var producer = await Account(app, "Producer"); using var trader = await Account(app, "Trader");
        using var admin = await Account(app, "Admin"); using var pending = await Account(app, "Consumer", ApprovalState.Pending);
        using var anonymous = app.CreateClient();
        foreach (var forbidden in new[] { admin, pending })
        { using var denied = await forbidden.PostAsJsonAsync("/api/v1/articles", Article()); Assert.Equal(HttpStatusCode.Forbidden, denied.StatusCode); }
        foreach (var seller in new[] { producer, trader })
        { using var missingBranch = await seller.PostAsJsonAsync("/api/v1/articles", Article()); Assert.Equal(HttpStatusCode.BadRequest, missingBranch.StatusCode); }
        using var unauthenticated = await anonymous.PostAsJsonAsync("/api/v1/articles", Article()); Assert.Equal(HttpStatusCode.Unauthorized, unauthenticated.StatusCode);
        using var supplyInjection = await consumer.PostAsJsonAsync("/api/v1/articles", new { title = "Community article", body = "Information, never a stock commitment.", estimatedQuantityKg = 20 }); Assert.Equal(HttpStatusCode.BadRequest, supplyInjection.StatusCode);
        using var business = await consumer.PostAsJsonAsync("/api/v1/posts", new { title = "Not a seller", body = "A consumer cannot submit a business forecast.", productCode = "mango", estimatedQuantityKg = 20 }); Assert.Equal(HttpStatusCode.Forbidden, business.StatusCode);
        const string body = "<script>alert('plain text')</script> Community observations only.";
        using var submitted = await consumer.PostAsJsonAsync("/api/v1/articles", new { title = "Fruit information from a consumer", body });
        Assert.Equal(HttpStatusCode.Created, submitted.StatusCode);
        Assert.StartsWith("application/json", submitted.Content.Headers.ContentType!.MediaType);
        var article = await submitted.Content.ReadFromJsonAsync<JsonElement>(); var id = article.GetProperty("id").GetGuid();
        Assert.Equal(body, article.GetProperty("body").GetString()); Assert.Equal("AwaitingReview", article.GetProperty("status").GetString());
        using var hidden = await anonymous.GetAsync($"/api/v1/articles/{id}"); Assert.Equal(HttpStatusCode.NotFound, hidden.StatusCode);
        var published = await Review(admin, "articles", id, "Published", 1);
        Assert.Equal(2, published.GetProperty("revision").GetInt32());
        var publicArticle = await Get(anonymous, $"/api/v1/articles/{id}");
        Assert.Equal(body, publicArticle.GetProperty("body").GetString()); Assert.False(publicArticle.TryGetProperty("reviewReason", out _));
        Assert.Equal("Consumer", publicArticle.GetProperty("author").GetProperty("role").GetString());
        Assert.Equal("Publishing integration test", (await Get(consumer, $"/api/v1/articles/{id}")).GetProperty("reviewReason").GetString());
    }

    [Fact]
    public async Task Article_revision_requeues_content_and_serializes_admin_review()
    {
        using var app = App(); using var owner = await Account(app, "Consumer"); using var stranger = await Account(app, "Consumer"); using var admin = await Account(app, "Admin");
        var id = (await SubmitArticle(owner)).GetProperty("id").GetGuid(); await Review(admin, "articles", id, "Published", 1);
        using var foreign = await stranger.PutAsJsonAsync($"/api/v1/articles/{id}", new { title = "Unowned article edit", body = "This must never be persisted.", expectedRevision = 2 }); Assert.Equal(HttpStatusCode.NotFound, foreign.StatusCode);
        using var update = await owner.PutAsJsonAsync($"/api/v1/articles/{id}", new { title = "Revised consumer information", body = "Changed information needs a new independent review.", expectedRevision = 2 });
        Assert.Equal(HttpStatusCode.OK, update.StatusCode); var revised = await update.Content.ReadFromJsonAsync<JsonElement>();
        Assert.Equal("AwaitingReview", revised.GetProperty("status").GetString()); Assert.Equal(3, revised.GetProperty("revision").GetInt32());
        using var hidden = await stranger.GetAsync($"/api/v1/articles/{id}"); Assert.Equal(HttpStatusCode.NotFound, hidden.StatusCode);
        using var stale = await owner.PutAsJsonAsync($"/api/v1/articles/{id}", new { title = "Stale competing update", body = "Never overwrite a newer revision.", expectedRevision = 2 }); Assert.Equal(HttpStatusCode.Conflict, stale.StatusCode);
        var reviews = await Task.WhenAll(Enumerable.Range(0, 2).Select(_ => admin.PostAsJsonAsync($"/api/v1/admin/articles/{id}/review", new { status = "Published", reason = "Concurrent review control", expectedRevision = 3 })));
        try { Assert.Single(reviews, response => response.StatusCode == HttpStatusCode.OK); Assert.Single(reviews, response => response.StatusCode == HttpStatusCode.Conflict); }
        finally { foreach (var response in reviews) response.Dispose(); }
        Assert.Equal(4, (await Get(owner, $"/api/v1/articles/{id}")).GetProperty("revision").GetInt32());
    }

    [Fact]
    public async Task Article_withdraw_cursor_and_author_eligibility_do_not_leak_private_reasons()
    {
        using var app = App(); using var owner = await Account(app, "Consumer"); using var admin = await Account(app, "Admin"); using var reader = app.CreateClient();
        var first = (await SubmitArticle(owner)).GetProperty("id").GetGuid(); await Review(admin, "articles", first, "Published", 1);
        var second = (await SubmitArticle(owner)).GetProperty("id").GetGuid(); await Review(admin, "articles", second, "Published", 1);
        var page = await Get(reader, "/api/v1/articles?limit=1"); Assert.Equal(second, page.GetProperty("items")[0].GetProperty("id").GetGuid());
        var next = await Get(reader, $"/api/v1/articles?limit=1&after={second}"); Assert.Equal(first, next.GetProperty("items")[0].GetProperty("id").GetGuid());
        using var cursor = await reader.GetAsync($"/api/v1/articles?after={Guid.NewGuid()}"); Assert.Equal(HttpStatusCode.BadRequest, cursor.StatusCode);
        using var withdraw = await owner.PostAsJsonAsync($"/api/v1/articles/{second}/withdraw", new { expectedRevision = 2 }); Assert.Equal(HttpStatusCode.OK, withdraw.StatusCode);
        using var hidden = await reader.GetAsync($"/api/v1/articles/{second}"); Assert.Equal(HttpStatusCode.NotFound, hidden.StatusCode);
        Assert.Equal("Paused", (await Get(owner, $"/api/v1/articles/{second}")).GetProperty("status").GetString());
        var ownerId = (await Get(owner, "/api/v1/auth/me")).GetProperty("id").GetGuid();
        using var scope = app.Services.CreateScope(); var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
        Assert.True(await db.AuditEntries.AnyAsync(a => a.SubjectId == ownerId && a.Action == "ArticleWithdrawn"));
        await db.Users.Where(u => u.Id == ownerId).ExecuteUpdateAsync(set => set.SetProperty(u => u.IsActive, false));
        using var inactive = await reader.GetAsync($"/api/v1/articles/{first}"); Assert.Equal(HttpStatusCode.NotFound, inactive.StatusCode);
    }

    [Fact]
    public async Task Seller_branches_validate_directory_selection_and_owner_boundaries()
    {
        using var app = App(); using var producer = await Account(app, "Producer"); using var stranger = await Account(app, "Trader"); using var consumer = await Account(app, "Consumer"); using var anonymous = app.CreateClient();
        using var forbidden = await consumer.PostAsJsonAsync("/api/v1/branches", Branch()); Assert.Equal(HttpStatusCode.Forbidden, forbidden.StatusCode);
        using var fakeRegion = await producer.PostAsJsonAsync("/api/v1/branches", new { name = "Farm branch", countryCode = "VN", provinceCode = "01", street = "123 Farm Road", phone = "0901234567", region = "Made up location" }); Assert.Equal(HttpStatusCode.BadRequest, fakeRegion.StatusCode);
        using var invalid = await producer.PostAsJsonAsync("/api/v1/branches", Branch(province: "99")); Assert.Equal(HttpStatusCode.BadRequest, invalid.StatusCode);
        using var create = await producer.PostAsJsonAsync("/api/v1/branches", Branch()); Assert.Equal(HttpStatusCode.Created, create.StatusCode);
        var branch = await create.Content.ReadFromJsonAsync<JsonElement>(); var id = branch.GetProperty("id").GetGuid();
        Assert.Equal("Pending", branch.GetProperty("status").GetString()); Assert.Equal("VN", branch.GetProperty("countryCode").GetString());
        Assert.Equal("Tỉnh thử 01, Việt Nam", branch.GetProperty("region").GetString());
        using var hidden = await anonymous.GetAsync($"/api/v1/branches/{id}"); Assert.Equal(HttpStatusCode.NotFound, hidden.StatusCode);
        using var foreign = await stranger.PutAsJsonAsync($"/api/v1/branches/{id}", Branch(revision: 1)); Assert.Equal(HttpStatusCode.NotFound, foreign.StatusCode);
        using var deniedList = await consumer.GetAsync("/api/v1/branches/mine"); Assert.Equal(HttpStatusCode.Forbidden, deniedList.StatusCode);
        Assert.Contains((await Get(producer, "/api/v1/branches/mine")).GetProperty("items").EnumerateArray(), row => row.GetProperty("id").GetGuid() == id);
    }

    [Fact]
    public async Task Branch_review_and_revisions_revoke_public_approval_and_post_eligibility()
    {
        using var app = App(); using var producer = await Account(app, "Producer"); using var stranger = await Account(app, "Trader"); using var admin = await Account(app, "Admin"); using var reader = app.CreateClient();
        using var create = await producer.PostAsJsonAsync("/api/v1/branches", Branch()); Assert.Equal(HttpStatusCode.Created, create.StatusCode);
        var id = (await create.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("id").GetGuid();
        var ownerId = (await Get(producer, "/api/v1/auth/me")).GetProperty("id").GetGuid(); var otherId = (await Get(stranger, "/api/v1/auth/me")).GetProperty("id").GetGuid();
        await Review(admin, "branches", id, "Approved", 1);
        var visible = await Get(reader, $"/api/v1/branches/{id}"); Assert.Equal("Approved", visible.GetProperty("status").GetString());
        Assert.False(visible.TryGetProperty("reviewReason", out _)); Assert.False(visible.TryGetProperty("phone", out _)); Assert.False(visible.TryGetProperty("street", out _));
        using (var scope = app.Services.CreateScope())
        {
            var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
            await using var transaction = await db.Database.BeginTransactionAsync();
            Assert.NotNull(await PublishingEndpoints.ValidateOwnedApprovedBranch(db, ownerId, id));
            Assert.Null(await PublishingEndpoints.ValidateOwnedApprovedBranch(db, otherId, id));
        }
        using var change = await producer.PutAsJsonAsync($"/api/v1/branches/{id}", Branch(revision: 2)); Assert.Equal(HttpStatusCode.OK, change.StatusCode);
        Assert.Equal("Pending", (await change.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("status").GetString());
        using var hidden = await reader.GetAsync($"/api/v1/branches/{id}"); Assert.Equal(HttpStatusCode.NotFound, hidden.StatusCode);
        using var scopeAfter = app.Services.CreateScope(); var dbAfter = scopeAfter.ServiceProvider.GetRequiredService<AppDbContext>();
        Assert.Null(await PublishingEndpoints.ValidateOwnedApprovedBranch(dbAfter, ownerId, id));
        Assert.True(await dbAfter.AuditEntries.AnyAsync(a => a.SubjectId == ownerId && a.Action == "BranchReviewed"));
    }

    [Fact]
    public async Task Branch_admin_review_is_revision_locked_and_requires_current_seller_approval()
    {
        using var app = App(); using var trader = await Account(app, "Trader"); using var admin = await Account(app, "Admin");
        using var create = await trader.PostAsJsonAsync("/api/v1/branches", Branch()); Assert.Equal(HttpStatusCode.Created, create.StatusCode);
        var id = (await create.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("id").GetGuid();
        var attempts = await Task.WhenAll(Enumerable.Range(0, 2).Select(_ => admin.PostAsJsonAsync($"/api/v1/admin/branches/{id}/review", new { status = "Approved", reason = "Revision conflict control", expectedRevision = 1 })));
        try { Assert.Single(attempts, response => response.StatusCode == HttpStatusCode.OK); Assert.Single(attempts, response => response.StatusCode == HttpStatusCode.Conflict); }
        finally { foreach (var response in attempts) response.Dispose(); }
        await Review(admin, "branches", id, "NeedsInformation", 2);
        using var resubmitted = await trader.PutAsJsonAsync($"/api/v1/branches/{id}", Branch(revision: 3));
        Assert.Equal(HttpStatusCode.OK, resubmitted.StatusCode);
        var ownerId = (await Get(trader, "/api/v1/auth/me")).GetProperty("id").GetGuid();
        using var scope = app.Services.CreateScope(); var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
        await db.Users.Where(u => u.Id == ownerId).ExecuteUpdateAsync(set => set.SetProperty(u => u.ApprovalStatus, ApprovalState.NeedsInformation));
        using var invalidApproval = await admin.PostAsJsonAsync($"/api/v1/admin/branches/{id}/review", new { status = "Approved", reason = "Cannot approve an ineligible owner", expectedRevision = 4 }); Assert.Equal(HttpStatusCode.Conflict, invalidApproval.StatusCode);
    }

    private WebApplicationFactory<Program> App() => fixture.WithWebHostBuilder(builder => builder.ConfigureServices(services =>
        services.AddSingleton(new LocationDirectory(new DirectoryProvider()))));
    private async Task<HttpClient> Account(WebApplicationFactory<Program> app, string role, ApprovalState approval = ApprovalState.Approved)
    {
        var email = $"publishing-{Guid.NewGuid():N}@example.test";
        using (var scope = app.Services.CreateScope())
        {
            var manager = scope.ServiceProvider.GetRequiredService<UserManager<AppUser>>();
            var user = new AppUser { Id = Guid.NewGuid(), UserName = email, Email = email, EmailConfirmed = true,
                DisplayName = "Publishing test", Region = "Test region", Role = Enum.Parse<AccountRole>(role), ApprovalStatus = approval, IsActive = true };
            Assert.True((await manager.CreateAsync(user, fixture.Password)).Succeeded);
        }
        var client = app.CreateClient(); using var response = await client.PostAsJsonAsync("/api/v1/auth/login", new { email, password = fixture.Password }); Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", (await response.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("accessToken").GetString()); return client;
    }
    private static object Article() => new { title = "Consumer community observations", body = "Information shared by a consumer, not a business supply offer." };
    private static object Branch(int? revision = null, string province = "01") => revision.HasValue
        ? new { name = "Reviewed farm branch", countryCode = "VN", provinceCode = province, street = "123 Farm Road", phone = "0901234567", expectedRevision = revision.Value }
        : (object)new { name = "Reviewed farm branch", countryCode = "VN", provinceCode = province, street = "123 Farm Road", phone = "0901234567" };
    private static async Task<JsonElement> SubmitArticle(HttpClient client)
    { using var response = await client.PostAsJsonAsync("/api/v1/articles", Article()); Assert.Equal(HttpStatusCode.Created, response.StatusCode); return await response.Content.ReadFromJsonAsync<JsonElement>(); }
    private static async Task<JsonElement> Review(HttpClient admin, string lane, Guid id, string status, int revision)
    { using var response = await admin.PostAsJsonAsync($"/api/v1/admin/{lane}/{id}/review", new { status, reason = "Publishing integration test", expectedRevision = revision }); Assert.Equal(HttpStatusCode.OK, response.StatusCode); return await response.Content.ReadFromJsonAsync<JsonElement>(); }
    private static async Task<JsonElement> Get(HttpClient client, string path)
    { using var response = await client.GetAsync(path); Assert.Equal(HttpStatusCode.OK, response.StatusCode); return await response.Content.ReadFromJsonAsync<JsonElement>(); }

    // Provider fixture is used only in this isolated test server; production always uses the trusted HTTP directory.
    private sealed class DirectoryProvider : HttpMessageHandler, IHttpClientFactory
    {
        private static readonly string[] Codes = Enumerable.Range(0, 110).Select(i => $"{(char)('A' + i / 26)}{(char)('A' + i % 26)}").Append("VN").ToArray();
        public HttpClient CreateClient(string name) => new(this, false);
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            object data = request.RequestUri!.Host switch
            {
                "restcountries.com" => Codes.Select(code => new { cca2 = code, name = new { common = code == "VN" ? "Vietnam" : "Country " + code } }).ToArray(),
                "raw.githubusercontent.com" => new { main = new { vi = new { localeDisplayNames = new { territories = Codes.ToDictionary(code => code, code => code == "VN" ? "Việt Nam" : "Country " + code) } } } },
                "provinces.open-api.vn" => Enumerable.Range(1, 34).Select(code => new { code, name = $"Tỉnh thử {code:D2}" }).ToArray(),
                _ => throw new InvalidOperationException("Unexpected provider in publishing fixture")
            };
            return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent(JsonSerializer.Serialize(data), Encoding.UTF8, "application/json") });
        }
    }
}
