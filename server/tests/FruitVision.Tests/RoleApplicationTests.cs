using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text.Json;
using FruitVision.Api.Data;
using FruitVision.Api.Infrastructure;
using FruitVision.Api.Auth;
using FruitVision.Api.Realtime;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Identity;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.AspNetCore.SignalR;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Xunit;

namespace FruitVision.Tests;

[Collection("Api")]
public sealed class RoleApplicationTests(ApiFixture fixture)
{
    private static readonly byte[] Png = Convert.FromBase64String("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=");

    [Fact]
    public async Task Submission_notifies_owner_and_admin_only_after_the_submitted_state_is_committed()
    {
        var notifications = new ApplicationNotifications();
        using var configured = CreateApp(); using var app = configured.WithWebHostBuilder(builder => builder.ConfigureServices(services => services.AddSingleton<IHubContext<FruitHub>>(notifications)));
        using var owner = await Account(app);
        notifications.OnEvent = async (method, payload) =>
        {
            if (method != "RoleApplicationChanged") return;
            var view = JsonSerializer.SerializeToElement(payload, new JsonSerializerOptions(JsonSerializerDefaults.Web));
            if (view.GetProperty("status").GetString() != "Submitted") return;
            using var scope = app.Services.CreateScope(); var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
            var saved = await db.Set<RoleApplication>().AsNoTracking().SingleAsync(a => a.Id == view.GetProperty("id").GetGuid());
            Assert.Equal("Submitted", saved.Status); Assert.NotNull(saved.SubmittedAt); Assert.Equal(saved.Revision, view.GetProperty("revision").GetInt32());
            Assert.Equal(new[] { "eventId", "id", "revision", "status" }, view.EnumerateObject().Select(p => p.Name).Order().ToArray());
            notifications.SubmittedDelivered = true;
        };
        await Submitted(owner);
        Assert.True(notifications.SubmittedDelivered); Assert.Contains("role:Admin", notifications.Audiences); Assert.Contains($"user:{owner.UserId}", notifications.Audiences);
    }

    [Fact]
    public async Task Admin_submitted_queue_is_not_the_legacy_signup_queue_and_orders_submission_with_public_applicant_identity()
    {
        using var app = CreateApp(); using var first = await Account(app); using var second = await Account(app); using var admin = await Account(app, "Admin");
        var firstId = await Submitted(first); var secondId = await Submitted(second);
        using (var scope = app.Services.CreateScope())
        {
            var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
            var firstRow = await db.Set<RoleApplication>().SingleAsync(a => a.Id == firstId); var secondRow = await db.Set<RoleApplication>().SingleAsync(a => a.Id == secondId);
            var future = DateTimeOffset.UtcNow.AddDays(100);
            firstRow.CreatedAt = future.AddDays(-20); firstRow.SubmittedAt = future;
            secondRow.CreatedAt = future.AddDays(-10); secondRow.SubmittedAt = future.AddDays(-1);
            await db.SaveChangesAsync();
        }
        var list = await Get(admin, "/api/v1/admin/role-applications?status=Submitted&limit=1");
        var item = Assert.Single(list.GetProperty("items").EnumerateArray()); Assert.Equal(firstId, item.GetProperty("id").GetGuid());
        var applicant = item.GetProperty("applicant"); Assert.Equal(first.UserId, applicant.GetProperty("id").GetGuid()); Assert.Equal("Role applicant", applicant.GetProperty("displayName").GetString()); Assert.Equal("Consumer", applicant.GetProperty("role").GetString());
        Assert.Equal(new[] { "displayName", "id", "role" }, applicant.EnumerateObject().Select(p => p.Name).Order().ToArray());
        var next = await Get(admin, "/api/v1/admin/role-applications?status=Submitted&limit=1&after=" + list.GetProperty("next").GetGuid()); Assert.Equal(secondId, next.GetProperty("items")[0].GetProperty("id").GetGuid());
        using var draftOwner = await Account(app); var draftId = await Draft(draftOwner);
        var submitted = await Get(admin, "/api/v1/admin/role-applications?status=Submitted&limit=50"); Assert.DoesNotContain(submitted.GetProperty("items").EnumerateArray(), row => row.GetProperty("id").GetGuid() == draftId);
        Assert.Equal("Draft", (await Get(admin, $"/api/v1/admin/role-applications/{draftId}")).GetProperty("status").GetString());
    }

    [Fact]
    public async Task Consumers_create_one_active_application_under_concurrency_and_others_cannot_read_it()
    {
        using var app = CreateApp();
        using var anonymous = app.CreateClient();
        using var unauthorized = await anonymous.GetAsync("/api/v1/role-applications");
        Assert.Equal(HttpStatusCode.Unauthorized, unauthorized.StatusCode);
        using var owner = await Account(app);
        using var outsider = await Account(app);
        var attempts = await Task.WhenAll(owner.PostAsJsonAsync("/api/v1/role-applications", new { requestedRole = "Producer" }), owner.PostAsJsonAsync("/api/v1/role-applications", new { requestedRole = "Trader" }));
        Assert.Single(attempts, r => r.StatusCode == HttpStatusCode.Created);
        Assert.Single(attempts, r => r.StatusCode == HttpStatusCode.Conflict);
        var draft = await attempts.Single(r => r.StatusCode == HttpStatusCode.Created).Content.ReadFromJsonAsync<JsonElement>();
        Assert.Equal("Draft", draft.GetProperty("status").GetString());
        Assert.Equal(1, draft.GetProperty("revision").GetInt32());
        var id = draft.GetProperty("id").GetGuid();
        using var hidden = await outsider.GetAsync($"/api/v1/role-applications/{id}");
        Assert.Equal(HttpStatusCode.NotFound, hidden.StatusCode);
        using var foreignEdit = await outsider.PutAsJsonAsync($"/api/v1/role-applications/{id}", Profile(1));
        using var foreignSubmit = await outsider.PostAsJsonAsync($"/api/v1/role-applications/{id}/submit", new { expectedRevision = 1 });
        using var foreignUpload = await Upload(outsider, id, 1);
        Assert.Equal(HttpStatusCode.NotFound, foreignEdit.StatusCode);
        Assert.Equal(HttpStatusCode.NotFound, foreignSubmit.StatusCode);
        Assert.Equal(HttpStatusCode.NotFound, foreignUpload.StatusCode);
        var list = await Get(owner, "/api/v1/role-applications");
        Assert.Single(list.GetProperty("items").EnumerateArray());
        Assert.DoesNotContain("storagePath", draft.GetRawText(), StringComparison.OrdinalIgnoreCase);
        foreach (var response in attempts) response.Dispose();
    }

    [Fact]
    public async Task Unverified_or_unapproved_consumers_cannot_start_role_upgrades()
    {
        using var app = CreateApp();
        foreach (var state in new[] { (Verified: false, Approval: ApprovalState.Approved), (Verified: true, Approval: ApprovalState.Pending) })
        {
            using var client = await Account(app, emailConfirmed: state.Verified, approval: state.Approval);
            using var response = await client.PostAsJsonAsync("/api/v1/role-applications", new { requestedRole = "Producer" });
            Assert.Equal(HttpStatusCode.Forbidden, response.StatusCode);
        }
    }

    [Theory]
    [InlineData("Producer")]
    [InlineData("Trader")]
    [InlineData("Admin")]
    public async Task Existing_business_roles_cannot_create_edit_upload_or_submit(string role)
    {
        using var app = CreateApp();
        using var client = await Account(app, role);
        using var create = await client.PostAsJsonAsync("/api/v1/role-applications", new { requestedRole = "Producer" });
        Assert.Equal(HttpStatusCode.Forbidden, create.StatusCode);
        var id = Guid.NewGuid();
        using var edit = await client.PutAsJsonAsync($"/api/v1/role-applications/{id}", Profile(1));
        Assert.Equal(HttpStatusCode.Forbidden, edit.StatusCode);
        using var upload = await Upload(client, id, 1);
        Assert.Equal(HttpStatusCode.Forbidden, upload.StatusCode);
        using var submit = await client.PostAsJsonAsync($"/api/v1/role-applications/{id}/submit", new { expectedRevision = 1 });
        Assert.Equal(HttpStatusCode.Forbidden, submit.StatusCode);
    }

    [Fact]
    public async Task Submission_requires_valid_profile_and_proof_then_freezes_fields_and_evidence()
    {
        using var app = CreateApp();
        using var owner = await Account(app);
        using var outsider = await Account(app);
        var id = await Draft(owner);
        using var noProfile = await owner.PostAsJsonAsync($"/api/v1/role-applications/{id}/submit", new { expectedRevision = 1 });
        Assert.Equal(HttpStatusCode.Conflict, noProfile.StatusCode);
        using var invalid = await owner.PutAsJsonAsync($"/api/v1/role-applications/{id}", new { organisationName = "Farm", address = "Address", countryCode = "VN", provinceCode = "79", phone = "0901234567", products = new[] { "mango" }, cultivatedAreaHa = 0, expectedRevision = 1 });
        Assert.Equal(HttpStatusCode.BadRequest, invalid.StatusCode);
        using var injection = await owner.PutAsJsonAsync($"/api/v1/role-applications/{id}", new { organisationName = "Farm", address = "Address", countryCode = "VN", provinceCode = "79", phone = "0901234567", products = new[] { "mango" }, cultivatedAreaHa = 2, expectedRevision = 1, role = "Admin" });
        Assert.Equal(HttpStatusCode.BadRequest, injection.StatusCode);
        using var edit = await owner.PutAsJsonAsync($"/api/v1/role-applications/{id}", Profile(1));
        Assert.Equal(HttpStatusCode.OK, edit.StatusCode);
        using var noProof = await owner.PostAsJsonAsync($"/api/v1/role-applications/{id}/submit", new { expectedRevision = 2 });
        Assert.Equal(HttpStatusCode.Conflict, noProof.StatusCode);
        using var proof = await Upload(owner, id, 2);
        Assert.Equal(HttpStatusCode.Created, proof.StatusCode);
        var uploaded = await proof.Content.ReadFromJsonAsync<JsonElement>();
        var evidence = uploaded.GetProperty("evidence")[0];
        var evidenceId = evidence.GetProperty("id").GetGuid();
        using var hidden = await outsider.GetAsync($"/api/v1/role-applications/{id}/evidence/{evidenceId}");
        Assert.Equal(HttpStatusCode.NotFound, hidden.StatusCode);
        using var submitted = await owner.PostAsJsonAsync($"/api/v1/role-applications/{id}/submit", new { expectedRevision = 3 });
        Assert.Equal(HttpStatusCode.OK, submitted.StatusCode);
        Assert.Equal("Submitted", (await submitted.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("status").GetString());
        using var frozenEdit = await owner.PutAsJsonAsync($"/api/v1/role-applications/{id}", Profile(4));
        using var frozenUpload = await Upload(owner, id, 4);
        using var frozenDelete = await owner.DeleteAsync($"/api/v1/role-applications/{id}/evidence/{evidenceId}?expectedRevision=4");
        Assert.Equal(HttpStatusCode.Conflict, frozenEdit.StatusCode);
        Assert.Equal(HttpStatusCode.Conflict, frozenUpload.StatusCode);
        Assert.Equal(HttpStatusCode.Conflict, frozenDelete.StatusCode);
    }

    [Fact]
    public async Task Admin_review_is_revision_atomic_updates_role_once_and_requires_current_eligible_consumer()
    {
        using var app = CreateApp();
        using var owner = await Account(app);
        using var outsider = await Account(app);
        using var admin = await Account(app, "Admin");
        var id = await Submitted(owner);
        using var unauthorized = await outsider.PostAsJsonAsync($"/api/v1/admin/role-applications/{id}/review", new { status = "Approved", reason = "Verified evidence", expectedRevision = 4 });
        Assert.Equal(HttpStatusCode.Forbidden, unauthorized.StatusCode);
        var reviews = await Task.WhenAll(admin.PostAsJsonAsync($"/api/v1/admin/role-applications/{id}/review", new { status = "Approved", reason = "Verified evidence", expectedRevision = 4 }), admin.PostAsJsonAsync($"/api/v1/admin/role-applications/{id}/review", new { status = "Approved", reason = "Verified evidence", expectedRevision = 4 }));
        Assert.Single(reviews, r => r.StatusCode == HttpStatusCode.OK);
        Assert.Single(reviews, r => r.StatusCode == HttpStatusCode.Conflict);
        Assert.Equal("Producer", (await Get(owner, "/api/v1/auth/me")).GetProperty("role").GetString());
        using var scope = app.Services.CreateScope();
        var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
        var user = await db.Users.SingleAsync(u => u.Id == owner.UserId);
        Assert.Equal(AccountRole.Producer, user.Role);
        Assert.Equal(ApprovalState.Approved, user.ApprovalStatus);
        Assert.Single(await db.AuditEntries.Where(a => a.SubjectId == user.Id && a.Action == "RoleApplicationApproved").ToListAsync());
        foreach (var response in reviews) response.Dispose();

        using var blocked = await Account(app);
        var blockedId = await Submitted(blocked);
        var target = await db.Users.SingleAsync(u => u.Id == blocked.UserId);
        target.IsActive = false;
        await db.SaveChangesAsync();
        using var denied = await admin.PostAsJsonAsync($"/api/v1/admin/role-applications/{blockedId}/review", new { status = "Approved", reason = "Should remain blocked", expectedRevision = 4 });
        Assert.Equal(HttpStatusCode.Conflict, denied.StatusCode);
    }

    [Fact]
    public async Task Needs_information_preserves_consumer_role_and_resubmission_uses_current_revision()
    {
        using var app = CreateApp();
        using var owner = await Account(app);
        using var admin = await Account(app, "Admin");
        var id = await Submitted(owner);
        using var review = await admin.PostAsJsonAsync($"/api/v1/admin/role-applications/{id}/review", new { status = "NeedsInformation", reason = "Provide updated details", expectedRevision = 4 });
        Assert.Equal(HttpStatusCode.OK, review.StatusCode);
        Assert.Equal("Consumer", (await Get(owner, "/api/v1/auth/me")).GetProperty("role").GetString());
        using var duplicate = await owner.PostAsJsonAsync("/api/v1/role-applications", new { requestedRole = "Trader" });
        Assert.Equal(HttpStatusCode.Conflict, duplicate.StatusCode);
        using var stale = await owner.PutAsJsonAsync($"/api/v1/role-applications/{id}", Profile(4));
        Assert.Equal(HttpStatusCode.Conflict, stale.StatusCode);
        using var edit = await owner.PutAsJsonAsync($"/api/v1/role-applications/{id}", Profile(5));
        Assert.Equal(HttpStatusCode.OK, edit.StatusCode);
        using var resubmit = await owner.PostAsJsonAsync($"/api/v1/role-applications/{id}/submit", new { expectedRevision = 6 });
        Assert.Equal(HttpStatusCode.OK, resubmit.StatusCode);
    }

    [Fact]
    public async Task Evidence_enforces_type_size_count_and_pdf_download_is_private_attachment()
    {
        using var app = CreateApp();
        using var owner = await Account(app);
        using var admin = await Account(app, "Admin");
        var id = await Draft(owner);
        using var mime = await Upload(owner, id, 1, "text/html", "<html>"u8.ToArray());
        using var magic = await Upload(owner, id, 1, "image/png", "not png"u8.ToArray());
        using var huge = await Upload(owner, id, 1, "image/png", new byte[5 * 1024 * 1024 + 1]);
        using var category = await Upload(owner, id, 1, category: "BusinessEvidence");
        Assert.Equal(HttpStatusCode.BadRequest, mime.StatusCode);
        Assert.Equal(HttpStatusCode.BadRequest, magic.StatusCode);
        Assert.Equal(HttpStatusCode.RequestEntityTooLarge, huge.StatusCode);
        Assert.Equal(HttpStatusCode.BadRequest, category.StatusCode);
        using var pdf = await Upload(owner, id, 1, "application/pdf", "%PDF-1.7\nprivate proof\n%%EOF"u8.ToArray());
        Assert.Equal(HttpStatusCode.Created, pdf.StatusCode);
        var evidence = (await pdf.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("evidence")[0];
        var path = evidence.GetProperty("downloadPath").GetString()!;
        using var download = await owner.GetAsync(path);
        Assert.Equal(HttpStatusCode.OK, download.StatusCode);
        Assert.Equal("attachment", download.Content.Headers.ContentDisposition?.DispositionType);
        using var adminDownload = await admin.GetAsync($"/api/v1/admin/role-applications/{id}/evidence/{evidence.GetProperty("id").GetGuid()}");
        Assert.Equal(HttpStatusCode.OK, adminDownload.StatusCode);
        for (var revision = 2; revision <= 4; revision++)
        {
            using var added = await Upload(owner, id, revision);
            Assert.Equal(HttpStatusCode.Created, added.StatusCode);
        }
        using var tooMany = await Upload(owner, id, 5);
        Assert.Equal(HttpStatusCode.Conflict, tooMany.StatusCode);
    }

    [Fact]
    public async Task Trader_requires_registration_and_business_proof_and_can_revise_after_rejection()
    {
        using var app = CreateApp();
        using var owner = await Account(app);
        using var admin = await Account(app, "Admin");
        using var create = await owner.PostAsJsonAsync("/api/v1/role-applications", new { requestedRole = "Trader" });
        Assert.Equal(HttpStatusCode.Created, create.StatusCode);
        var id = (await create.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("id").GetGuid();
        object TraderProfile(int revision, string? registration) => new { organisationName = "Demo trader", address = "456 Market Road", countryCode = "VN", provinceCode = "79", phone = "+84901234567", products = new[] { "mango" }, businessRegistrationNumber = registration, expectedRevision = revision };
        using var invalid = await owner.PutAsJsonAsync($"/api/v1/role-applications/{id}", TraderProfile(1, null));
        Assert.Equal(HttpStatusCode.BadRequest, invalid.StatusCode);
        using var valid = await owner.PutAsJsonAsync($"/api/v1/role-applications/{id}", TraderProfile(1, "REG-12345"));
        Assert.Equal(HttpStatusCode.OK, valid.StatusCode);
        using var wrongProof = await Upload(owner, id, 2);
        Assert.Equal(HttpStatusCode.BadRequest, wrongProof.StatusCode);
        using var proof = await Upload(owner, id, 2, category: "BusinessEvidence");
        Assert.Equal(HttpStatusCode.Created, proof.StatusCode);
        using var submitted = await owner.PostAsJsonAsync($"/api/v1/role-applications/{id}/submit", new { expectedRevision = 3 });
        Assert.Equal(HttpStatusCode.OK, submitted.StatusCode);
        using var reject = await admin.PostAsJsonAsync($"/api/v1/admin/role-applications/{id}/review", new { status = "Rejected", reason = "Please correct registration", expectedRevision = 4 });
        Assert.Equal(HttpStatusCode.OK, reject.StatusCode);
        using var correction = await owner.PutAsJsonAsync($"/api/v1/role-applications/{id}", TraderProfile(5, "REG-98765"));
        Assert.Equal(HttpStatusCode.OK, correction.StatusCode);
        using var resubmitted = await owner.PostAsJsonAsync($"/api/v1/role-applications/{id}/submit", new { expectedRevision = 6 });
        Assert.Equal(HttpStatusCode.OK, resubmitted.StatusCode);
        using var approve = await admin.PostAsJsonAsync($"/api/v1/admin/role-applications/{id}/review", new { status = "Approved", reason = "Corrected business proof", expectedRevision = 7 });
        Assert.Equal(HttpStatusCode.OK, approve.StatusCode);
        Assert.Equal("Trader", (await Get(owner, "/api/v1/auth/me")).GetProperty("role").GetString());
    }

    private WebApplicationFactory<Program> CreateApp()
    {
        var root = Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "../../../../../.local/role-evidence-tests", Guid.NewGuid().ToString("N")));
        return fixture.WithWebHostBuilder(b => b.ConfigureAppConfiguration((_, c) => c.AddInMemoryCollection(new Dictionary<string, string?> { ["RoleEvidence:RootPath"] = root }))
            .ConfigureServices(services => services.AddSingleton<IHttpClientFactory>(new GeographyProvider())));
    }

    private async Task<AccountClient> Account(WebApplicationFactory<Program> app, string role = "Consumer", bool emailConfirmed = true, ApprovalState approval = ApprovalState.Approved)
    {
        var email = $"upgrade.{Guid.NewGuid():N}@fruitvision.test";
        using (var scope = app.Services.CreateScope())
        {
            var users = scope.ServiceProvider.GetRequiredService<UserManager<AppUser>>();
            var user = new AppUser { Id = Guid.NewGuid(), UserName = email, Email = email, EmailConfirmed = emailConfirmed, DisplayName = "Role applicant", Region = "Đồng Tháp", Role = Enum.Parse<AccountRole>(role), ApprovalStatus = approval, IsActive = true };
            Assert.True((await users.CreateAsync(user, fixture.Password)).Succeeded);
        }
        var client = new AccountClient(app.CreateClient());
        if (!emailConfirmed)
        {
            // An already-issued session can become unverified after an account/email change.
            // Provision only that isolated state; password login must retain its real OTP gate.
            using var scope = app.Services.CreateScope();
            var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
            var user = await db.Users.SingleAsync(u => u.Email == email);
            var (session, access, _) = SessionTokens.Create(user);
            db.AuthSessions.Add(session);
            await db.SaveChangesAsync();
            client.Inner.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", access);
            client.UserId = user.Id;
            return client;
        }
        using var login = await client.PostAsJsonAsync("/api/v1/auth/login", new { email, password = fixture.Password });
        Assert.Equal(HttpStatusCode.OK, login.StatusCode);
        var response = await login.Content.ReadFromJsonAsync<JsonElement>();
        client.Inner.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", response.GetProperty("accessToken").GetString());
        client.UserId = response.GetProperty("user").GetProperty("id").GetGuid();
        return client;
    }

    private static object Profile(int revision) => new { organisationName = "Demo farm", address = "123 Farm Road", countryCode = "VN", provinceCode = "79", phone = "0901234567", products = new[] { "mango" }, cultivatedAreaHa = 2.5m, expectedRevision = revision };
    private static async Task<Guid> Draft(AccountClient client)
    {
        using var response = await client.PostAsJsonAsync("/api/v1/role-applications", new { requestedRole = "Producer" });
        Assert.Equal(HttpStatusCode.Created, response.StatusCode);
        return (await response.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("id").GetGuid();
    }
    private static async Task<Guid> Submitted(AccountClient client)
    {
        var id = await Draft(client);
        using var edit = await client.PutAsJsonAsync($"/api/v1/role-applications/{id}", Profile(1));
        Assert.Equal(HttpStatusCode.OK, edit.StatusCode);
        using var proof = await Upload(client, id, 2);
        Assert.Equal(HttpStatusCode.Created, proof.StatusCode);
        using var submit = await client.PostAsJsonAsync($"/api/v1/role-applications/{id}/submit", new { expectedRevision = 3 });
        Assert.Equal(HttpStatusCode.OK, submit.StatusCode);
        return id;
    }
    private static Task<HttpResponseMessage> Upload(AccountClient client, Guid id, int revision, string contentType = "image/png", byte[]? bytes = null, string category = "ProductionEvidence")
    {
        var content = new ByteArrayContent(bytes ?? Png);
        content.Headers.ContentType = new MediaTypeHeaderValue(contentType);
        return client.Inner.PostAsync($"/api/v1/role-applications/{id}/evidence?category={category}&expectedRevision={revision}", content);
    }
    private static async Task<JsonElement> Get(AccountClient client, string path)
    {
        using var response = await client.GetAsync(path);
        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        return await response.Content.ReadFromJsonAsync<JsonElement>();
    }
    private sealed class AccountClient(HttpClient inner) : IDisposable
    {
        public HttpClient Inner { get; } = inner;
        public Guid UserId { get; set; }
        public Task<HttpResponseMessage> GetAsync(string path) => Inner.GetAsync(path);
        public Task<HttpResponseMessage> DeleteAsync(string path) => Inner.DeleteAsync(path);
        public Task<HttpResponseMessage> PostAsJsonAsync<T>(string path, T body) => Inner.PostAsJsonAsync(path, body);
        public Task<HttpResponseMessage> PutAsJsonAsync<T>(string path, T body) => Inner.PutAsJsonAsync(path, body);
        public void Dispose() => Inner.Dispose();
    }

    private sealed class ApplicationNotifications : IHubContext<FruitHub>, IHubClients, IClientProxy
    {
        public Func<string, object?, Task>? OnEvent { get; set; }
        public bool SubmittedDelivered { get; set; }
        public List<string> Audiences { get; } = [];
        IHubClients IHubContext<FruitHub>.Clients => this;
        IGroupManager IHubContext<FruitHub>.Groups => throw new NotSupportedException();
        public IClientProxy Group(string name) { Audiences.Add(name); return this; }
        public IClientProxy Groups(IReadOnlyList<string> names) { Audiences.AddRange(names); return this; }
        public IClientProxy All => throw new NotSupportedException();
        public IClientProxy AllExcept(IReadOnlyList<string> ids) => throw new NotSupportedException();
        public IClientProxy Client(string id) => throw new NotSupportedException();
        public IClientProxy Clients(IReadOnlyList<string> ids) => throw new NotSupportedException();
        public IClientProxy GroupExcept(string name, IReadOnlyList<string> ids) => throw new NotSupportedException();
        public IClientProxy User(string id) => throw new NotSupportedException();
        public IClientProxy Users(IReadOnlyList<string> ids) => throw new NotSupportedException();
        public Task SendCoreAsync(string method, object?[] args, CancellationToken ct = default) => OnEvent?.Invoke(method, args[0]) ?? Task.CompletedTask;
    }

    // The real LocationDirectory validates these bounded provider responses; tests never contact
    // external geography services or substitute a production validation bypass.
    private sealed class GeographyProvider : HttpMessageHandler, IHttpClientFactory
    {
        private static readonly string[] Countries = Enumerable.Range(0, 110).Select(i => $"{(char)('A' + i / 26)}{(char)('A' + i % 26)}").Append("VN").Distinct().ToArray();
        public HttpClient CreateClient(string name)
        {
            Assert.Equal(LocationDirectory.HttpClientName, name);
            return new(this, disposeHandler: false);
        }
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            object body = request.RequestUri!.Host switch
            {
                "restcountries.com" => Countries.Select(code => new { cca2 = code, name = new { common = "Fixture country " + code } }).ToArray(),
                "raw.githubusercontent.com" => new { main = new { vi = new { localeDisplayNames = new { territories = Countries.ToDictionary(code => code, code => code == "VN" ? "Việt Nam" : "Quốc gia thử " + code) } } } },
                "provinces.open-api.vn" => Enumerable.Range(1, 33).Append(79).Select(code => new { code, name = "Tỉnh thử " + code }).ToArray(),
                _ => throw new InvalidOperationException("Unexpected geography provider in isolated fixture.")
            };
            return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK) { Content = JsonContent.Create(body) });
        }
    }
}
