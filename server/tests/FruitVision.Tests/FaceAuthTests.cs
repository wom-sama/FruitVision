using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Security.Cryptography;
using System.Text.Json;
using FruitVision.Api.Auth;
using FruitVision.Api.Data;
using Microsoft.AspNetCore.DataProtection;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Identity;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Xunit;

namespace FruitVision.Tests;

[Collection("Api")]
public sealed class FaceAuthTests(ApiFixture fixture)
{
    // Decoder/inference are replaced only for these API authorization tests. Actual synthetic worker evidence is separate.
    private const string Image = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=";

    [Fact]
    public async Task Enrollment_encrypts_128D_template_per_user_and_never_returns_biometrics()
    {
        var mail = new Mailer(); var engine = new Engine(); using var app = App(mail, engine); using var account = await Account(app, mail);
        using var enrollment = await account.Client.PostAsJsonAsync("/api/v1/auth/face/enroll", new { imageBase64 = Image }); Assert.Equal(HttpStatusCode.Created, enrollment.StatusCode);
        var snapshot = await enrollment.Content.ReadFromJsonAsync<JsonElement>(); Assert.True(snapshot.GetProperty("enrolled").GetBoolean()); Assert.False(snapshot.GetProperty("livenessVerified").GetBoolean()); Assert.False(snapshot.TryGetProperty("embedding", out _));
        using var scope = app.Services.CreateScope(); var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
        var stored = await db.Set<FaceIdentity>().AsNoTracking().SingleAsync(face => face.UserId == account.Id);
        Assert.Equal(FaceEngine.ModelSha256, stored.ModelSha256); Assert.DoesNotContain("[1,0,0", stored.ProtectedEmbedding);
        var protection = scope.ServiceProvider.GetRequiredService<IDataProtectionProvider>();
        var plaintext = protection.CreateProtector("FruitVision.Face.v1").CreateProtector(account.Id.ToString("D")).Unprotect(stored.ProtectedEmbedding);
        Assert.Equal(128, JsonSerializer.Deserialize<double[]>(plaintext)!.Length);
        Assert.Throws<CryptographicException>(() => protection.CreateProtector("FruitVision.Face.v1").CreateProtector(Guid.NewGuid().ToString("D")).Unprotect(stored.ProtectedEmbedding));
        var status = await Get(account.Client, "/api/v1/auth/face/status"); Assert.True(status.GetProperty("enrolled").GetBoolean());
        Assert.True(await db.AuditEntries.AnyAsync(a => a.SubjectId == account.Id && a.Action == "FaceEnrolled"));
    }

    [Fact]
    public async Task Stale_or_weak_session_cannot_enroll_overwrite_or_revoke_face()
    {
        var mail = new Mailer(); var engine = new Engine(); using var app = App(mail, engine); using var account = await Account(app, mail);
        using var scope = app.Services.CreateScope(); var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
        await db.AuthSessions.Where(s => s.UserId == account.Id).ExecuteUpdateAsync(set => set.SetProperty(s => s.AuthMethod, "password"));
        using var weak = await account.Client.PostAsJsonAsync("/api/v1/auth/face/enroll", new { imageBase64 = Image }); Assert.Equal(HttpStatusCode.Forbidden, weak.StatusCode);
        Assert.Equal(0, engine.Calls);
        await db.AuthSessions.Where(s => s.UserId == account.Id).ExecuteUpdateAsync(set => set.SetProperty(s => s.AuthMethod, "password_email_otp").SetProperty(s => s.CreatedAt, DateTimeOffset.UtcNow.AddMinutes(-16)));
        using var stale = await account.Client.PostAsJsonAsync("/api/v1/auth/face/enroll", new { imageBase64 = Image }); Assert.Equal(HttpStatusCode.Forbidden, stale.StatusCode);
        using var revoke = await account.Client.DeleteAsync("/api/v1/auth/face"); Assert.Equal(HttpStatusCode.Forbidden, revoke.StatusCode);
        Assert.False(await db.Set<FaceIdentity>().AnyAsync(face => face.UserId == account.Id));
    }

    [Fact]
    public async Task Face_match_requires_email_otp_and_does_not_issue_a_face_only_session()
    {
        var mail = new Mailer(); var engine = new Engine(); using var app = App(mail, engine); using var account = await Account(app, mail); using var anonymous = app.CreateClient();
        using var enrollment = await account.Client.PostAsJsonAsync("/api/v1/auth/face/enroll", new { imageBase64 = Image }); Assert.Equal(HttpStatusCode.Created, enrollment.StatusCode);
        await Cooldown(app, account.Id);
        using var login = await anonymous.PostAsJsonAsync("/api/v1/auth/face/login", new { email = account.Email, imageBase64 = Image }); Assert.Equal(HttpStatusCode.OK, login.StatusCode);
        var challenge = await login.Content.ReadFromJsonAsync<JsonElement>(); Assert.True(challenge.GetProperty("requiresTwoFactor").GetBoolean()); Assert.Equal("email", challenge.GetProperty("method").GetString()); Assert.False(challenge.TryGetProperty("accessToken", out _));
        using (var scope = app.Services.CreateScope()) Assert.Equal(1, await scope.ServiceProvider.GetRequiredService<AppDbContext>().AuthSessions.CountAsync(s => s.UserId == account.Id));
        using var verified = await anonymous.PostAsJsonAsync("/api/v1/auth/otp/verify", new { challengeToken = challenge.GetProperty("challengeToken").GetString(), code = mail.Sent[^1].Code }); Assert.Equal(HttpStatusCode.OK, verified.StatusCode);
        using var finalScope = app.Services.CreateScope(); var db = finalScope.ServiceProvider.GetRequiredService<AppDbContext>();
        Assert.True(await db.AuthSessions.AnyAsync(s => s.UserId == account.Id && s.AuthMethod == "face_email_otp"));
    }

    [Fact]
    public async Task Face_revoke_invalidates_pending_email_challenge_and_totp_cannot_be_bypassed()
    {
        var mail = new Mailer(); var engine = new Engine(); using var app = App(mail, engine); using var account = await Account(app, mail); using var anonymous = app.CreateClient();
        using var enrollment = await account.Client.PostAsJsonAsync("/api/v1/auth/face/enroll", new { imageBase64 = Image }); Assert.Equal(HttpStatusCode.Created, enrollment.StatusCode);
        await Cooldown(app, account.Id);
        using var login = await anonymous.PostAsJsonAsync("/api/v1/auth/face/login", new { email = account.Email, imageBase64 = Image }); Assert.Equal(HttpStatusCode.OK, login.StatusCode);
        var challenge = await login.Content.ReadFromJsonAsync<JsonElement>(); var code = mail.Sent[^1].Code;
        using var revoke = await account.Client.DeleteAsync("/api/v1/auth/face"); Assert.Equal(HttpStatusCode.NoContent, revoke.StatusCode);
        using var invalid = await anonymous.PostAsJsonAsync("/api/v1/auth/otp/verify", new { challengeToken = challenge.GetProperty("challengeToken").GetString(), code }); Assert.Equal(HttpStatusCode.Unauthorized, invalid.StatusCode);
        using var reenroll = await account.Client.PostAsJsonAsync("/api/v1/auth/face/enroll", new { imageBase64 = Image }); Assert.Equal(HttpStatusCode.Created, reenroll.StatusCode);
        using var scope = app.Services.CreateScope(); var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
        await db.Users.Where(u => u.Id == account.Id).ExecuteUpdateAsync(set => set.SetProperty(u => u.TwoFactorEnabled, true));
        var before = mail.Sent.Count;
        using var blocked = await anonymous.PostAsJsonAsync("/api/v1/auth/face/login", new { email = account.Email, imageBase64 = Image }); Assert.Equal(HttpStatusCode.Unauthorized, blocked.StatusCode); Assert.Equal(before, mail.Sent.Count);
    }

    [Fact]
    public async Task Mismatch_unknown_user_and_unavailable_engine_never_authenticate_or_persist_image()
    {
        var mail = new Mailer(); var engine = new Engine(); using var app = App(mail, engine); using var account = await Account(app, mail); using var anonymous = app.CreateClient();
        using var enrollment = await account.Client.PostAsJsonAsync("/api/v1/auth/face/enroll", new { imageBase64 = Image }); Assert.Equal(HttpStatusCode.Created, enrollment.StatusCode);
        engine.Match = false; var before = mail.Sent.Count;
        using var mismatch = await anonymous.PostAsJsonAsync("/api/v1/auth/face/login", new { email = account.Email, imageBase64 = Image }); Assert.Equal(HttpStatusCode.Unauthorized, mismatch.StatusCode);
        using var unknown = await anonymous.PostAsJsonAsync("/api/v1/auth/face/login", new { email = "unknown@example.test", imageBase64 = Image }); Assert.Equal(HttpStatusCode.Unauthorized, unknown.StatusCode); Assert.Equal(before, mail.Sent.Count);
        engine.IsReady = false;
        using var unavailable = await account.Client.PostAsJsonAsync("/api/v1/auth/face/enroll", new { imageBase64 = Image }); Assert.Equal(HttpStatusCode.ServiceUnavailable, unavailable.StatusCode);
    }

    private WebApplicationFactory<Program> App(Mailer mail, Engine engine) => fixture.WithWebHostBuilder(builder => builder
        .ConfigureAppConfiguration((_, config) => config.AddInMemoryCollection(new Dictionary<string, string?>
        { ["EmailOtp:HashKey"] = Convert.ToBase64String(Enumerable.Repeat((byte)71, 32).ToArray()), ["EmailOtp:RequireOnPasswordLogin"] = "true" }))
        .ConfigureServices(services => { services.AddSingleton<IEmailOtpMailer>(mail); services.AddSingleton<IFaceEngine>(engine); }));
    private async Task<FaceAccount> Account(WebApplicationFactory<Program> app, Mailer mail)
    {
        var email = $"face-{Guid.NewGuid():N}@example.test"; var id = Guid.NewGuid();
        using (var scope = app.Services.CreateScope())
        {
            var users = scope.ServiceProvider.GetRequiredService<UserManager<AppUser>>();
            Assert.True((await users.CreateAsync(new AppUser { Id = id, UserName = email, Email = email, EmailConfirmed = true, DisplayName = "Face API test", Role = AccountRole.Consumer, ApprovalStatus = ApprovalState.Approved, IsActive = true, LockoutEnabled = true }, fixture.Password)).Succeeded);
        }
        var client = app.CreateClient(); using var login = await client.PostAsJsonAsync("/api/v1/auth/login", new { email, password = fixture.Password }); Assert.Equal(HttpStatusCode.OK, login.StatusCode);
        var challenge = await login.Content.ReadFromJsonAsync<JsonElement>();
        using var verified = await client.PostAsJsonAsync("/api/v1/auth/otp/verify", new { challengeToken = challenge.GetProperty("challengeToken").GetString(), code = mail.Sent[^1].Code }); Assert.Equal(HttpStatusCode.OK, verified.StatusCode);
        client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", (await verified.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("accessToken").GetString());
        return new FaceAccount(client, id, email);
    }
    private static async Task Cooldown(WebApplicationFactory<Program> app, Guid id)
    { using var scope = app.Services.CreateScope(); await scope.ServiceProvider.GetRequiredService<AppDbContext>().Set<EmailOtpChallenge>().Where(c => c.UserId == id).ExecuteUpdateAsync(set => set.SetProperty(c => c.SentAt, DateTimeOffset.UtcNow.AddMinutes(-2))); }
    private static async Task<JsonElement> Get(HttpClient client, string path)
    { using var result = await client.GetAsync(path); Assert.Equal(HttpStatusCode.OK, result.StatusCode); return await result.Content.ReadFromJsonAsync<JsonElement>(); }
    private sealed record FaceAccount(HttpClient Client, Guid Id, string Email) : IDisposable { public void Dispose() => Client.Dispose(); }
    private sealed class Engine : IFaceEngine
    {
        public bool IsReady { get; set; } = true;
        public bool Match = true;
        public int Calls;
        public Task<double[]> ExtractAsync(string imageBase64, CancellationToken cancellationToken)
        { Interlocked.Increment(ref Calls); var values = new double[128]; values[Match ? 0 : 1] = 1; return Task.FromResult(values); }
    }
    private sealed class Mailer : IEmailOtpMailer
    {
        public bool IsReady => true;
        public readonly List<(string Code, string Purpose)> Sent = [];
        public Task SendAsync(string recipient, string code, string purpose, CancellationToken ct)
        { Sent.Add((code, purpose)); return Task.CompletedTask; }
    }
}
