using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Security.Cryptography;
using System.Text.Json;
using FruitVision.Api.Data;
using FruitVision.Api.Infrastructure;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Identity;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Xunit;

namespace FruitVision.Tests;

[Collection("Api")]
public sealed class NormalMediaTests(ApiFixture fixture)
{
    private static readonly byte[] Png = Convert.FromBase64String("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=");

    [Fact]
    public async Task Normal_article_and_chat_uploads_share_quota_and_leave_no_new_files_or_messages_when_full()
    {
        var processor = new TestProcessor();
        using var app = App(processor, new Dictionary<string, string?> {
            ["MediaLimits:UserStoredBytes"] = "4", ["MediaLimits:TotalStoredBytes"] = "2147483648", ["MediaLimits:MinimumFreeDiskBytes"] = "1" });
        using var owner = await Account(app, "Consumer"); var group = await Group(owner.Http);
        await Upload(owner.Http, "/api/v1/articles/images");
        using var chat = await UploadResponse(owner.Http, $"/api/v1/conversations/{group}/images?clientMessageId={Guid.NewGuid():N}");
        Assert.Equal(HttpStatusCode.Conflict, chat.StatusCode);
        using var article = await UploadResponse(owner.Http, "/api/v1/articles/images"); Assert.Equal(HttpStatusCode.Conflict, article.StatusCode);
        using var scope = app.Services.CreateScope(); var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
        Assert.Equal(1, await db.Set<NormalImage>().CountAsync(i => i.OwnerId == owner.Id));
        Assert.False(await db.Messages.AnyAsync(m => m.ConversationId == group));
        Assert.Single(Directory.EnumerateFiles(processor.Root, "*", SearchOption.AllDirectories));
        Assert.Empty(Directory.EnumerateFiles(Path.Combine(processor.Root, ".staging")));
    }

    [Fact]
    public async Task Article_image_is_owner_bound_reviewed_and_hidden_again_on_withdrawal()
    {
        using var app = App(); using var owner = await Account(app, "Consumer"); using var other = await Account(app, "Consumer");
        using var admin = await Account(app, "Admin"); using var anonymous = app.CreateClient();
        var image = await Upload(owner.Http, "/api/v1/articles/images"); var imageId = image.GetProperty("id").GetGuid();
        Assert.Equal("image/jpeg", image.GetProperty("contentType").GetString());
        Assert.False(image.TryGetProperty("downloadPath", out _));
        using var stolen = await other.Http.PostAsJsonAsync("/api/v1/articles", Article(imageId));
        Assert.Equal(HttpStatusCode.BadRequest, stolen.StatusCode);
        var article = await Submit(owner.Http, Article(imageId)); var id = article.GetProperty("id").GetGuid();
        Assert.Equal("Community", article.GetProperty("audienceLane").GetString());
        Assert.Equal(imageId, article.GetProperty("image").GetProperty("id").GetGuid());
        var path = article.GetProperty("image").GetProperty("downloadPath").GetString()!;
        Assert.Equal($"/api/v1/articles/{id}/image", path);
        using var hidden = await anonymous.GetAsync(path); Assert.Equal(HttpStatusCode.NotFound, hidden.StatusCode);
        using var privateImage = await owner.Http.GetAsync(path); Assert.Equal(HttpStatusCode.OK, privateImage.StatusCode);
        using var adminImage = await admin.Http.GetAsync(path); Assert.Equal(HttpStatusCode.OK, adminImage.StatusCode);
        using var reused = await owner.Http.PostAsJsonAsync("/api/v1/articles", Article(imageId)); Assert.Equal(HttpStatusCode.BadRequest, reused.StatusCode);
        await Review(admin.Http, "articles", id, "Published", 1);
        using var visible = await anonymous.GetAsync(path); Assert.Equal(HttpStatusCode.OK, visible.StatusCode);
        Assert.Equal("image/jpeg", visible.Content.Headers.ContentType!.MediaType);
        Assert.Contains("no-store", visible.Headers.CacheControl!.ToString());
        using var withdraw = await owner.Http.PostAsJsonAsync($"/api/v1/articles/{id}/withdraw", new { expectedRevision = 2 }); Assert.Equal(HttpStatusCode.OK, withdraw.StatusCode);
        using var withdrawn = await anonymous.GetAsync(path); Assert.Equal(HttpStatusCode.NotFound, withdrawn.StatusCode);
    }

    [Fact]
    public async Task Professional_lane_requires_owned_approved_branch_and_snapshot_survives_upgrade()
    {
        using var app = App(); using var seller = await Account(app, "Producer"); using var consumer = await Account(app, "Consumer");
        using var admin = await Account(app, "Admin"); using var anonymous = app.CreateClient();
        using var missing = await seller.Http.PostAsJsonAsync("/api/v1/articles", Article()); Assert.Equal(HttpStatusCode.BadRequest, missing.StatusCode);
        var branch = await Branch(app, seller.Id, "Pending");
        using var pending = await seller.Http.PostAsJsonAsync("/api/v1/articles", Article(branchId: branch)); Assert.Equal(HttpStatusCode.Conflict, pending.StatusCode);
        using var invalidConsumer = await consumer.Http.PostAsJsonAsync("/api/v1/articles", Article(branchId: branch)); Assert.Equal(HttpStatusCode.BadRequest, invalidConsumer.StatusCode);
        using var injectedLane = await consumer.Http.PostAsJsonAsync("/api/v1/articles", new { title = "Caller cannot assign lane", body = "This is a consumer observation about mango.", audienceLane = "Professional" }); Assert.Equal(HttpStatusCode.BadRequest, injectedLane.StatusCode);
        await Review(admin.Http, "branches", branch, "Approved", 1);
        var imageId = (await Upload(seller.Http, "/api/v1/articles/images")).GetProperty("id").GetGuid();
        var professional = await Submit(seller.Http, Article(imageId, branch)); var professionalId = professional.GetProperty("id").GetGuid();
        Assert.Equal("Professional", professional.GetProperty("audienceLane").GetString());
        await Review(admin.Http, "articles", professionalId, "Published", 1);
        var listed = await anonymous.GetFromJsonAsync<JsonElement>("/api/v1/articles?lane=Professional");
        Assert.Contains(listed.GetProperty("items").EnumerateArray(), row => row.GetProperty("id").GetGuid() == professionalId);
        var community = await Submit(consumer.Http, Article()); var communityId = community.GetProperty("id").GetGuid();
        using (var scope = app.Services.CreateScope())
            await scope.ServiceProvider.GetRequiredService<AppDbContext>().Users.Where(u => u.Id == consumer.Id).ExecuteUpdateAsync(set => set.SetProperty(u => u.Role, AccountRole.Trader));
        await Relogin(consumer);
        using var edit = await consumer.Http.PutAsJsonAsync($"/api/v1/articles/{communityId}", new { title = "Edited old community observation", body = "The author has changed role but the original lane must remain.", expectedRevision = 1 });
        Assert.Equal(HttpStatusCode.OK, edit.StatusCode);
        Assert.Equal("Community", (await edit.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("audienceLane").GetString());
        await Review(admin.Http, "branches", branch, "NeedsInformation", 2);
        using var hidden = await anonymous.GetAsync($"/api/v1/articles/{professionalId}/image"); Assert.Equal(HttpStatusCode.NotFound, hidden.StatusCode);
        using var invalid = await anonymous.GetAsync("/api/v1/articles?lane=Business"); Assert.Equal(HttpStatusCode.BadRequest, invalid.StatusCode);
    }

    [Fact]
    public async Task Chat_image_is_idempotent_private_and_revoked_for_departed_members()
    {
        using var app = App(); using var owner = await Account(app, "Producer"); using var member = await Account(app, "Consumer");
        using var admin = await Account(app, "Admin");
        var group = await Group(owner.Http); var key = Guid.NewGuid().ToString("N");
        using var joined = await member.Http.PostAsJsonAsync($"/api/v1/community/groups/{group}/join", new { }); Assert.Equal(HttpStatusCode.Created, joined.StatusCode);
        var sends = await Task.WhenAll(Enumerable.Range(0, 3).Select(_ => UploadResponse(owner.Http, $"/api/v1/conversations/{group}/images?clientMessageId={key}")));
        JsonElement message;
        try
        {
            Assert.Single(sends, r => r.StatusCode == HttpStatusCode.Created); Assert.Equal(2, sends.Count(r => r.StatusCode == HttpStatusCode.OK));
            var messages = await Task.WhenAll(sends.Select(r => r.Content.ReadFromJsonAsync<JsonElement>()));
            Assert.Single(messages.Select(m => m.GetProperty("id").GetGuid()).Distinct()); message = messages[0];
        }
        finally { foreach (var response in sends) response.Dispose(); }
        Assert.Equal("[Hình ảnh]", message.GetProperty("text").GetString());
        var image = message.GetProperty("image"); var path = image.GetProperty("downloadPath").GetString()!;
        using var allowed = await member.Http.GetAsync(path); Assert.Equal(HttpStatusCode.OK, allowed.StatusCode);
        using var noAdminShortcut = await admin.Http.GetAsync(path); Assert.Equal(HttpStatusCode.NotFound, noAdminShortcut.StatusCode);
        using var mismatch = await UploadResponse(owner.Http, $"/api/v1/conversations/{group}/images?clientMessageId={key}", Png.Concat(new byte[] { 1 }).ToArray()); Assert.Equal(HttpStatusCode.Conflict, mismatch.StatusCode);
        using var textCollision = await owner.Http.PostAsJsonAsync($"/api/v1/conversations/{group}/messages", new { text = "[Hình ảnh]", clientMessageId = key }); Assert.Equal(HttpStatusCode.Conflict, textCollision.StatusCode);
        var history = await member.Http.GetFromJsonAsync<JsonElement>($"/api/v1/conversations/{group}/messages");
        Assert.Contains(history.GetProperty("items").EnumerateArray(), m => m.GetProperty("id").GetGuid() == message.GetProperty("id").GetGuid() && m.GetProperty("image").GetProperty("id").GetGuid() == image.GetProperty("id").GetGuid());
        using var leave = await member.Http.PostAsJsonAsync($"/api/v1/community/groups/{group}/leave", new { }); Assert.Equal(HttpStatusCode.OK, leave.StatusCode);
        using var revoked = await member.Http.GetAsync(path); Assert.Equal(HttpStatusCode.NotFound, revoked.StatusCode);
        using var close = await owner.Http.PostAsJsonAsync($"/api/v1/community/groups/{group}/close", new { }); Assert.Equal(HttpStatusCode.OK, close.StatusCode);
        using var closedRead = await owner.Http.GetAsync(path); Assert.Equal(HttpStatusCode.OK, closedRead.StatusCode);
        using var closedSend = await UploadResponse(owner.Http, $"/api/v1/conversations/{group}/images?clientMessageId={Guid.NewGuid():N}"); Assert.Equal(HttpStatusCode.Conflict, closedSend.StatusCode);
        using var scope = app.Services.CreateScope(); var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
        Assert.Equal(1, await db.Messages.CountAsync(m => m.ConversationId == group));
        Assert.True(await db.OutboxEvents.AnyAsync(e => e.MessageId == message.GetProperty("id").GetGuid()));
    }

    [Fact]
    public async Task Upload_bounds_magic_processor_failure_and_unauthorized_requests_fail_without_metadata()
    {
        var processor = new TestProcessor(); using var app = App(processor); using var owner = await Account(app, "Consumer");
        using var pending = await Account(app, "Consumer", ApprovalState.Pending); using var anonymous = app.CreateClient();
        using var noLogin = await UploadResponse(anonymous, "/api/v1/articles/images"); Assert.Equal(HttpStatusCode.Unauthorized, noLogin.StatusCode);
        using var noApproval = await UploadResponse(pending.Http, "/api/v1/articles/images"); Assert.Equal(HttpStatusCode.Forbidden, noApproval.StatusCode);
        using var huge = await UploadResponse(owner.Http, "/api/v1/articles/images", new byte[5 * 1024 * 1024 + 1]); Assert.Equal(HttpStatusCode.RequestEntityTooLarge, huge.StatusCode);
        using var wrongType = await UploadResponse(owner.Http, "/api/v1/articles/images", Png, "image/jpeg"); Assert.Equal(HttpStatusCode.UnprocessableEntity, wrongType.StatusCode);
        using var wrongMagic = await UploadResponse(owner.Http, "/api/v1/articles/images", new byte[] { 1, 2, 3 }); Assert.Equal(HttpStatusCode.UnprocessableEntity, wrongMagic.StatusCode);
        processor.Failure = new NormalImageException(422, "IMAGE_INVALID");
        using var invalid = await UploadResponse(owner.Http, "/api/v1/articles/images"); Assert.Equal(HttpStatusCode.UnprocessableEntity, invalid.StatusCode);
        processor.Failure = new NormalImageException(503, "IMAGE_PROCESSOR_UNAVAILABLE");
        using var unavailable = await UploadResponse(owner.Http, "/api/v1/articles/images"); Assert.Equal(HttpStatusCode.ServiceUnavailable, unavailable.StatusCode);
        using var scope = app.Services.CreateScope(); Assert.False(await scope.ServiceProvider.GetRequiredService<AppDbContext>().Set<NormalImage>().AnyAsync(i => i.OwnerId == owner.Id));
        Assert.Empty(Directory.EnumerateFiles(processor.Root, "*", SearchOption.AllDirectories));
    }

    private WebApplicationFactory<Program> App(TestProcessor? processor = null, Dictionary<string, string?>? limits = null)
    {
        processor ??= new TestProcessor();
        var settings = new Dictionary<string, string?> { ["NormalMedia:RootPath"] = processor.Root };
        if (limits is not null) foreach (var setting in limits) settings[setting.Key] = setting.Value;
        return fixture.WithWebHostBuilder(builder => builder.ConfigureAppConfiguration((_, config) => config.AddInMemoryCollection(settings))
            .ConfigureServices(services => services.AddSingleton<INormalImageProcessor>(processor)));
    }
    private async Task<Actor> Account(WebApplicationFactory<Program> app, string role, ApprovalState approval = ApprovalState.Approved)
    {
        var email = $"normal-media-{Guid.NewGuid():N}@example.test"; var id = Guid.NewGuid();
        using (var scope = app.Services.CreateScope())
            Assert.True((await scope.ServiceProvider.GetRequiredService<UserManager<AppUser>>().CreateAsync(new AppUser { Id = id, UserName = email, Email = email, EmailConfirmed = true, DisplayName = "Normal media fixture", IsActive = true, Role = Enum.Parse<AccountRole>(role), ApprovalStatus = approval }, fixture.Password)).Succeeded);
        var actor = new Actor(id, email, app.CreateClient()); await Relogin(actor); return actor;
    }
    private async Task Relogin(Actor actor)
    {
        actor.Http.DefaultRequestHeaders.Authorization = null;
        using var login = await actor.Http.PostAsJsonAsync("/api/v1/auth/login", new { email = actor.Email, password = fixture.Password }); Assert.Equal(HttpStatusCode.OK, login.StatusCode);
        actor.Http.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", (await login.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("accessToken").GetString());
    }
    private static object Article(Guid? imageId = null, Guid? branchId = null) => new { title = "Mango knowledge observation", body = "An observation about mango and its visible surface, with no trade or quantity claim.", imageId, branchId };
    private static async Task<JsonElement> Submit(HttpClient client, object body) { using var r = await client.PostAsJsonAsync("/api/v1/articles", body); Assert.Equal(HttpStatusCode.Created, r.StatusCode); return await r.Content.ReadFromJsonAsync<JsonElement>(); }
    private static async Task Review(HttpClient admin, string kind, Guid id, string status, int revision) { using var r = await admin.PostAsJsonAsync($"/api/v1/admin/{kind}/{id}/review", new { status, reason = "Declared test fixture review", expectedRevision = revision }); Assert.Equal(HttpStatusCode.OK, r.StatusCode); }
    private static async Task<Guid> Branch(WebApplicationFactory<Program> app, Guid owner, string status) { using var scope = app.Services.CreateScope(); var db = scope.ServiceProvider.GetRequiredService<AppDbContext>(); var b = new SellerBranch { OwnerId = owner, Name = "Declared test branch", CountryCode = "VN", ProvinceCode = "79", CountryName = "Việt Nam", ProvinceName = "Test only", Region = "Test only", Street = "Fixture only", Phone = "0901234567", Status = status }; db.Add(b); await db.SaveChangesAsync(); return b.Id; }
    private static async Task<Guid> Group(HttpClient owner) { using var r = await owner.PostAsJsonAsync("/api/v1/community/groups", new { title = "Mango image conversation", region = "Declared test region", productCode = "mango" }); Assert.Equal(HttpStatusCode.Created, r.StatusCode); return (await r.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("id").GetGuid(); }
    private static async Task<JsonElement> Upload(HttpClient client, string path) { using var r = await UploadResponse(client, path); Assert.Equal(HttpStatusCode.Created, r.StatusCode); return await r.Content.ReadFromJsonAsync<JsonElement>(); }
    private static Task<HttpResponseMessage> UploadResponse(HttpClient client, string path, byte[]? bytes = null, string contentType = "image/png") { var content = new ByteArrayContent(bytes ?? Png); content.Headers.ContentType = new MediaTypeHeaderValue(contentType); return client.PostAsync(path, content); }
    private sealed record Actor(Guid Id, string Email, HttpClient Http) : IDisposable { public void Dispose() => Http.Dispose(); }
    private sealed class TestProcessor : INormalImageProcessor
    {
        public string Root { get; } = Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "../../../../../.local/normal-media-tests", Guid.NewGuid().ToString("N")));
        public NormalImageException? Failure { get; set; }
        public bool IsReady => true;
        public async Task<ProcessedNormalImage> ProcessAsync(string inputPath, string outputPath, CancellationToken ct)
        {
            if (Failure is not null) throw Failure;
            // Trusted processor fake isolates HTTP/DB authorization; actual Pillow is tested separately.
            byte[] canonical = [255, 216, 255, 217]; await File.WriteAllBytesAsync(outputPath, canonical, ct);
            return new(1, 1, canonical.Length, Convert.ToHexString(SHA256.HashData(canonical)).ToLowerInvariant());
        }
    }
}
