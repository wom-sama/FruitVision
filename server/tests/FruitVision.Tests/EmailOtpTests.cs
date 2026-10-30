using System.Net;
using System.Net.Http.Json;
using System.Text;
using System.Text.Json;
using FruitVision.Api.Auth;
using FruitVision.Api.Data;
using FruitVision.Api.Infrastructure;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Identity;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;
using Xunit;

namespace FruitVision.Tests;

[Collection("Api")]
public sealed class EmailOtpTests(ApiFixture fixture)
{
    private sealed class Mailer : IEmailOtpMailer
    {
        public bool IsReady => true;
        public bool Fail;
        public readonly List<(string Recipient, string Code, string Purpose)> Sent = [];
        public Task SendAsync(string recipient, string code, string purpose, CancellationToken ct)
        {
            if (Fail) throw new HttpRequestException("Test delivery failure");
            Sent.Add((recipient, code, purpose)); return Task.CompletedTask;
        }
    }
    private sealed class Geo : HttpMessageHandler, IHttpClientFactory
    {
        private static readonly string[] Codes = Enumerable.Range(0, 110).Select(i => $"{(char)('A' + i / 26)}{(char)('A' + i % 26)}").Append("VN").ToArray();
        public HttpClient CreateClient(string name) => new(this, false);
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
        {
            object body = request.RequestUri!.Host switch
            {
                "restcountries.com" => Codes.Select(c => new { cca2 = c, name = new { common = "Country " + c } }),
                "raw.githubusercontent.com" => new { main = new { vi = new { localeDisplayNames = new { territories = Codes.ToDictionary(c => c, c => c == "VN" ? "Việt Nam" : "Country " + c) } } } },
                "provinces.open-api.vn" => Enumerable.Range(1, 34).Select(i => new { code = i, name = "Tỉnh " + i.ToString("D2") }),
                _ => throw new InvalidOperationException("Unexpected external request")
            };
            return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent(JsonSerializer.Serialize(body), Encoding.UTF8, "application/json") });
        }
    }
    private WebApplicationFactory<Program> App(Mailer mailer) => fixture.WithWebHostBuilder(b =>
    {
        b.ConfigureAppConfiguration((_, c) => c.AddInMemoryCollection(new Dictionary<string, string?> {
            ["EmailOtp:HashKey"] = Convert.ToBase64String(new byte[32]), ["EmailOtp:RequireOnPasswordLogin"] = "true"
        }));
        b.ConfigureServices(s => { s.RemoveAll<IEmailOtpMailer>(); s.AddSingleton<IEmailOtpMailer>(mailer); s.RemoveAll<LocationDirectory>(); s.AddSingleton(new LocationDirectory(new Geo())); });
    });

    [Fact]
    public async Task Registration_is_consumer_only_email_verified_before_session_and_code_cannot_replay()
    {
        var mailer = new Mailer(); using var app = App(mailer); using var client = app.CreateClient();
        var email = $"otp-{Guid.NewGuid():N}@example.test";
        using var response = await client.PostAsJsonAsync("/api/v1/auth/register", new { displayName = "New Consumer", email, password = fixture.Password, countryCode = "VN", provinceCode = "01" });
        Assert.Equal(HttpStatusCode.Created, response.StatusCode);
        var challenge = await response.Content.ReadFromJsonAsync<JsonElement>();
        Assert.Equal("Consumer", challenge.GetProperty("user").GetProperty("role").GetString());
        Assert.False(challenge.GetProperty("user").GetProperty("emailConfirmed").GetBoolean());
        Assert.False(challenge.TryGetProperty("accessToken", out _));
        Assert.Single(mailer.Sent); Assert.Equal(email, mailer.Sent[0].Recipient);
        var token = challenge.GetProperty("challengeToken").GetString(); var code = mailer.Sent[0].Code;
        using (var scope = app.Services.CreateScope())
        {
            var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
            var saved = await db.Set<EmailOtpChallenge>().SingleAsync(x => x.Hash == SessionTokens.Hash(token!));
            Assert.NotEqual(code, saved.CodeHash); Assert.DoesNotContain(code, JsonSerializer.Serialize(saved));
        }
        using var accepted = await client.PostAsJsonAsync("/api/v1/auth/otp/verify", new { challengeToken = token, code });
        Assert.Equal(HttpStatusCode.OK, accepted.StatusCode);
        var session = await accepted.Content.ReadFromJsonAsync<JsonElement>();
        Assert.True(session.TryGetProperty("accessToken", out _)); Assert.True(session.GetProperty("user").GetProperty("emailConfirmed").GetBoolean());
        Assert.Equal("Approved", session.GetProperty("user").GetProperty("approvalStatus").GetString());
        using var replay = await client.PostAsJsonAsync("/api/v1/auth/otp/verify", new { challengeToken = token, code });
        Assert.Equal(HttpStatusCode.Unauthorized, replay.StatusCode);
    }

    [Fact]
    public async Task Wrong_attempts_exhaust_challenge_and_resend_has_cooldown()
    {
        var mailer = new Mailer(); using var app = App(mailer); using var c = app.CreateClient();
        var email = await Provision(app);
        var challenge = await Challenge(c, email); var token = challenge.GetProperty("challengeToken").GetString();
        using var early = await c.PostAsJsonAsync("/api/v1/auth/otp/resend", new { challengeToken = token });
        Assert.Equal(HttpStatusCode.TooManyRequests, early.StatusCode); Assert.Single(mailer.Sent);
        for (var i = 0; i < 5; i++)
        {
            var wrong = mailer.Sent[0].Code == "000000" ? "111111" : "000000";
            using var failure = await c.PostAsJsonAsync("/api/v1/auth/otp/verify", new { challengeToken = token, code = wrong });
            Assert.Equal(HttpStatusCode.Unauthorized, failure.StatusCode);
        }
        using var exhausted = await c.PostAsJsonAsync("/api/v1/auth/otp/verify", new { challengeToken = token, code = mailer.Sent[0].Code });
        Assert.Equal(HttpStatusCode.Unauthorized, exhausted.StatusCode);
    }

    [Fact]
    public async Task Resend_invalidates_old_code_and_other_account_stamp_or_expiry_invalidates_challenge()
    {
        var mailer = new Mailer(); using var app = App(mailer); using var c = app.CreateClient();
        var email = await Provision(app); var challenge = await Challenge(c, email); var token = challenge.GetProperty("challengeToken").GetString()!;
        var old = mailer.Sent[0].Code;
        using (var scope = app.Services.CreateScope()) await scope.ServiceProvider.GetRequiredService<AppDbContext>().Set<EmailOtpChallenge>().Where(x => x.Hash == SessionTokens.Hash(token)).ExecuteUpdateAsync(s => s.SetProperty(x => x.SentAt, DateTimeOffset.UtcNow.AddMinutes(-2)));
        using var resend = await c.PostAsJsonAsync("/api/v1/auth/otp/resend", new { challengeToken = token });
        Assert.Equal(HttpStatusCode.OK, resend.StatusCode); Assert.Equal(2, mailer.Sent.Count);
        Assert.NotEqual(old, mailer.Sent[1].Code);
        using var wrong = await c.PostAsJsonAsync("/api/v1/auth/otp/verify", new { challengeToken = token, code = old }); Assert.Equal(HttpStatusCode.Unauthorized, wrong.StatusCode);
        using (var scope = app.Services.CreateScope())
        {
            var users = scope.ServiceProvider.GetRequiredService<UserManager<AppUser>>(); var user = await users.FindByEmailAsync(email);
            Assert.True((await users.UpdateSecurityStampAsync(user!)).Succeeded);
        }
        using var revoked = await c.PostAsJsonAsync("/api/v1/auth/otp/verify", new { challengeToken = token, code = mailer.Sent[1].Code }); Assert.Equal(HttpStatusCode.Unauthorized, revoked.StatusCode);
        var second = await Provision(app); var secondChallenge = await Challenge(c, second); var secondToken = secondChallenge.GetProperty("challengeToken").GetString()!;
        using (var scope = app.Services.CreateScope()) await scope.ServiceProvider.GetRequiredService<AppDbContext>().Set<EmailOtpChallenge>().Where(x => x.Hash == SessionTokens.Hash(secondToken)).ExecuteUpdateAsync(s => s.SetProperty(x => x.ExpiresAt, DateTimeOffset.UtcNow.AddSeconds(-1)));
        using var expired = await c.PostAsJsonAsync("/api/v1/auth/otp/verify", new { challengeToken = secondToken, code = mailer.Sent[^1].Code }); Assert.Equal(HttpStatusCode.Unauthorized, expired.StatusCode);
    }

    [Fact]
    public async Task Transport_failure_never_claims_otp_sent_or_issues_a_session()
    {
        var mailer = new Mailer { Fail = true }; using var app = App(mailer); using var c = app.CreateClient(); var email = await Provision(app);
        using var response = await c.PostAsJsonAsync("/api/v1/auth/login", new { email, password = fixture.Password });
        Assert.Equal(HttpStatusCode.ServiceUnavailable, response.StatusCode); Assert.DoesNotContain("accessToken", await response.Content.ReadAsStringAsync());
        using var scope = app.Services.CreateScope(); var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
        var id = await db.Users.Where(u => u.Email == email).Select(u => u.Id).SingleAsync();
        Assert.False(await db.AuthSessions.AnyAsync(s => s.UserId == id)); Assert.False(await db.Set<EmailOtpChallenge>().AnyAsync(s => s.UserId == id));
    }
    private async Task<string> Provision(WebApplicationFactory<Program> app)
    {
        using var scope = app.Services.CreateScope(); var users = scope.ServiceProvider.GetRequiredService<UserManager<AppUser>>();
        var email = $"otp-{Guid.NewGuid():N}@example.test";
        var result = await users.CreateAsync(new AppUser { Id = Guid.NewGuid(), Email = email, UserName = email, DisplayName = "OTP account", Role = AccountRole.Consumer, ApprovalStatus = ApprovalState.Approved, EmailConfirmed = true, LockoutEnabled = true }, fixture.Password);
        Assert.True(result.Succeeded); return email;
    }
    private async Task<JsonElement> Challenge(HttpClient c, string email)
    {
        using var response = await c.PostAsJsonAsync("/api/v1/auth/login", new { email, password = fixture.Password });
        Assert.Equal(HttpStatusCode.OK, response.StatusCode); var body = await response.Content.ReadFromJsonAsync<JsonElement>(); Assert.True(body.GetProperty("requiresTwoFactor").GetBoolean()); return body;
    }
}
