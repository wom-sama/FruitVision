using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using FruitVision.Api.Auth;
using FruitVision.Api.Data;
using Microsoft.AspNetCore.Identity;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
using Xunit;

namespace FruitVision.Tests;

[Collection("Api")]
public sealed class DeviceBiometricTests(ApiFixture fixture)
{
    private const string Base = "/api/v1/auth/biometric";

    [Fact]
    public async Task Real_rsa_proof_creates_bound_session_and_concurrent_replay_succeeds_only_once()
    {
        using var user = await Identity();
        using var rsa = RSA.Create(2048);
        var deviceId = Guid.NewGuid();
        var device = await Enroll(user.Http, deviceId, rsa);
        using var anonymous = fixture.CreateClient();
        var challenge = await Challenge(anonymous, user.User.Email!, deviceId);
        var payload = challenge.GetProperty("payload").GetString()!;
        using var payloadJson = JsonDocument.Parse(payload);
        Assert.Equal("FruitVision", payloadJson.RootElement.GetProperty("issuer").GetString());
        Assert.Equal(user.User.Id, payloadJson.RootElement.GetProperty("userId").GetGuid());
        Assert.Equal(deviceId, payloadJson.RootElement.GetProperty("deviceId").GetGuid());
        var proof = Proof(challenge, rsa);
        var replies = await Task.WhenAll(anonymous.PostAsJsonAsync(Base + "/login", proof), anonymous.PostAsJsonAsync(Base + "/login", proof));
        Assert.Single(replies, reply => reply.StatusCode == HttpStatusCode.OK);
        Assert.Single(replies, reply => reply.StatusCode == HttpStatusCode.Unauthorized);
        var session = await replies.Single(reply => reply.StatusCode == HttpStatusCode.OK).Content.ReadFromJsonAsync<JsonElement>();
        var token = session.GetProperty("accessToken").GetString()!;
        Assert.Equal(user.User.Id, session.GetProperty("user").GetProperty("id").GetGuid());
        using var scope = fixture.Services.CreateScope();
        var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
        var persisted = await db.AuthSessions.SingleAsync(s => s.AccessHash == SessionTokens.Hash(token));
        Assert.Equal("device_biometric", persisted.AuthMethod);
        Assert.Equal(device.GetProperty("id").GetGuid(), persisted.BiometricDeviceId);
        Assert.Equal(1, await db.Set<BiometricChallenge>().CountAsync(c => c.Hash == SessionTokens.Hash(challenge.GetProperty("challengeToken").GetString()!) && c.ConsumedAt != null));
        foreach (var reply in replies) reply.Dispose();
    }

    [Fact]
    public async Task Enrollment_requires_recent_strong_auth_and_verified_email()
    {
        using var rsa = RSA.Create(2048);
        foreach (var state in new[] { (Method: "password", Age: 0, Verified: true), (Method: "refresh", Age: 0, Verified: true), (Method: "password_email_otp", Age: 16, Verified: true), (Method: "password_totp", Age: 0, Verified: false) })
        {
            using var user = await Identity(state.Method, state.Age, state.Verified);
            using var response = await user.Http.PostAsJsonAsync(Base + "/devices", Enrollment(Guid.NewGuid(), rsa));
            Assert.Equal(HttpStatusCode.Forbidden, response.StatusCode);
        }
        using var valid = await Identity("password_totp");
        await Enroll(valid.Http, Guid.NewGuid(), rsa);
    }

    [Fact]
    public async Task Wrong_signature_is_consumed_and_wrong_user_or_unknown_device_is_generic_unauthorized()
    {
        using var user = await Identity();
        using var other = await Identity();
        using var key = RSA.Create(2048);
        using var wrongKey = RSA.Create(2048);
        var deviceId = Guid.NewGuid();
        await Enroll(user.Http, deviceId, key);
        using var anonymous = fixture.CreateClient();
        foreach (var request in new[] { new { email = other.User.Email!, deviceId }, new { email = user.User.Email!, deviceId = Guid.NewGuid() }, new { email = "unknown.biometric@fruitvision.test", deviceId } })
        {
            using var unknown = await anonymous.PostAsJsonAsync(Base + "/challenge", request);
            Assert.Equal(HttpStatusCode.Unauthorized, unknown.StatusCode);
        }
        var challenge = await Challenge(anonymous, user.User.Email!, deviceId);
        using var invalid = await anonymous.PostAsJsonAsync(Base + "/login", Proof(challenge, wrongKey));
        Assert.Equal(HttpStatusCode.Unauthorized, invalid.StatusCode);
        using var reused = await anonymous.PostAsJsonAsync(Base + "/login", Proof(challenge, key));
        Assert.Equal(HttpStatusCode.Unauthorized, reused.StatusCode);
    }

    [Fact]
    public async Task Expired_or_old_security_stamp_challenges_never_issue_sessions()
    {
        using var user = await Identity();
        using var key = RSA.Create(2048);
        var deviceId = Guid.NewGuid();
        await Enroll(user.Http, deviceId, key);
        using var anonymous = fixture.CreateClient();
        var expired = await Challenge(anonymous, user.User.Email!, deviceId);
        using (var scope = fixture.Services.CreateScope())
        {
            var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
            var hash = SessionTokens.Hash(expired.GetProperty("challengeToken").GetString()!);
            var row = await db.Set<BiometricChallenge>().SingleAsync(c => c.Hash == hash);
            row.ExpiresAt = DateTimeOffset.UtcNow.AddSeconds(-1);
            await db.SaveChangesAsync();
        }
        using var expiry = await anonymous.PostAsJsonAsync(Base + "/login", Proof(expired, key));
        Assert.Equal(HttpStatusCode.Unauthorized, expiry.StatusCode);
        var oldStamp = await Challenge(anonymous, user.User.Email!, deviceId);
        using (var scope = fixture.Services.CreateScope())
        {
            var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
            var account = await db.Users.SingleAsync(u => u.Id == user.User.Id);
            account.SecurityStamp = Guid.NewGuid().ToString();
            await db.SaveChangesAsync();
        }
        using var stamp = await anonymous.PostAsJsonAsync(Base + "/login", Proof(oldStamp, key));
        Assert.Equal(HttpStatusCode.Unauthorized, stamp.StatusCode);
    }

    [Fact]
    public async Task Device_revocation_hides_other_owners_invalidates_nonces_and_revokes_bound_sessions()
    {
        using var user = await Identity();
        using var outsider = await Identity();
        using var key = RSA.Create(2048);
        var deviceId = Guid.NewGuid();
        var device = await Enroll(user.Http, deviceId, key);
        var id = device.GetProperty("id").GetGuid();
        using var anonymous = fixture.CreateClient();
        var challenge = await Challenge(anonymous, user.User.Email!, deviceId);
        using var signedIn = await anonymous.PostAsJsonAsync(Base + "/login", Proof(challenge, key));
        Assert.Equal(HttpStatusCode.OK, signedIn.StatusCode);
        var token = (await signedIn.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("accessToken").GetString();
        var pending = await Challenge(anonymous, user.User.Email!, deviceId);
        using var denied = await outsider.Http.DeleteAsync(Base + "/devices/" + id);
        Assert.Equal(HttpStatusCode.NotFound, denied.StatusCode);
        using var revoked = await user.Http.DeleteAsync(Base + "/devices/" + id);
        Assert.Equal(HttpStatusCode.NoContent, revoked.StatusCode);
        using var oldNonce = await anonymous.PostAsJsonAsync(Base + "/login", Proof(pending, key));
        Assert.Equal(HttpStatusCode.Unauthorized, oldNonce.StatusCode);
        using var oldSession = fixture.CreateClient();
        oldSession.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", token);
        using var profile = await oldSession.GetAsync("/api/v1/auth/me");
        Assert.Equal(HttpStatusCode.Unauthorized, profile.StatusCode);
        var devices = await user.Http.GetFromJsonAsync<JsonElement>(Base + "/devices");
        Assert.Single(devices.GetProperty("items").EnumerateArray());
        Assert.NotEqual(JsonValueKind.Null, devices.GetProperty("items")[0].GetProperty("revokedAt").ValueKind);
        Assert.False(devices.GetProperty("items")[0].TryGetProperty("publicKey", out _));
    }

    [Fact]
    public async Task Key_rotation_invalidates_prior_key_hash_snapshot_and_bound_sessions()
    {
        using var user = await Identity();
        using var oldKey = RSA.Create(2048);
        using var newKey = RSA.Create(2048);
        var deviceId = Guid.NewGuid();
        var original = await Enroll(user.Http, deviceId, oldKey);
        using var anonymous = fixture.CreateClient();
        var oldChallenge = await Challenge(anonymous, user.User.Email!, deviceId);
        using var rotated = await user.Http.PostAsJsonAsync(Base + "/devices", Enrollment(deviceId, newKey));
        Assert.Equal(HttpStatusCode.OK, rotated.StatusCode);
        Assert.Equal(original.GetProperty("id").GetGuid(), (await rotated.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("id").GetGuid());
        using var denied = await anonymous.PostAsJsonAsync(Base + "/login", Proof(oldChallenge, oldKey));
        Assert.Equal(HttpStatusCode.Unauthorized, denied.StatusCode);
        var current = await Challenge(anonymous, user.User.Email!, deviceId);
        using var success = await anonymous.PostAsJsonAsync(Base + "/login", Proof(current, newKey));
        Assert.Equal(HttpStatusCode.OK, success.StatusCode);
    }

    [Fact]
    public async Task Enrollment_rejects_weak_or_untrusted_input_and_serializes_the_ten_active_device_limit()
    {
        using var user = await Identity();
        using var weakKey = RSA.Create(1024);
        using var weak = await user.Http.PostAsJsonAsync(Base + "/devices", Enrollment(Guid.NewGuid(), weakKey));
        Assert.Equal(HttpStatusCode.BadRequest, weak.StatusCode);
        using var key = RSA.Create(2048);
        using var assertion = await user.Http.PostAsJsonAsync(Base + "/devices", new { deviceId = Guid.NewGuid(), label = "Device", publicKey = Convert.ToBase64String(key.ExportSubjectPublicKeyInfo()), biometricVerified = true });
        Assert.Equal(HttpStatusCode.BadRequest, assertion.StatusCode);
        for (var i = 0; i < 9; i++) await Enroll(user.Http, Guid.NewGuid(), key);
        var concurrent = await Task.WhenAll(user.Http.PostAsJsonAsync(Base + "/devices", Enrollment(Guid.NewGuid(), key)), user.Http.PostAsJsonAsync(Base + "/devices", Enrollment(Guid.NewGuid(), key)));
        Assert.Single(concurrent, response => response.StatusCode == HttpStatusCode.Created);
        Assert.Single(concurrent, response => response.StatusCode == HttpStatusCode.Conflict);
        foreach (var response in concurrent) response.Dispose();
    }

    private async Task<UserSession> Identity(string method = "password_email_otp", int ageMinutes = 0, bool verified = true)
    {
        var email = $"biometric.{Guid.NewGuid():N}@fruitvision.test";
        var user = new AppUser { Id = Guid.NewGuid(), UserName = email, Email = email, EmailConfirmed = verified, DisplayName = "Biometric fixture", Role = AccountRole.Consumer, ApprovalStatus = ApprovalState.Approved, IsActive = true };
        using var scope = fixture.Services.CreateScope();
        Assert.True((await scope.ServiceProvider.GetRequiredService<UserManager<AppUser>>().CreateAsync(user, fixture.Password)).Succeeded);
        var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
        var (session, access, _) = SessionTokens.Create(user, method);
        session.CreatedAt = DateTimeOffset.UtcNow.AddMinutes(-ageMinutes);
        db.AuthSessions.Add(session);
        await db.SaveChangesAsync();
        var client = fixture.CreateClient();
        client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", access);
        return new(user, client);
    }
    private static object Enrollment(Guid deviceId, RSA key) => new { deviceId, label = "Private test device", publicKey = Convert.ToBase64String(key.ExportSubjectPublicKeyInfo()) };
    private static async Task<JsonElement> Enroll(HttpClient client, Guid deviceId, RSA key)
    {
        using var response = await client.PostAsJsonAsync(Base + "/devices", Enrollment(deviceId, key));
        Assert.Equal(HttpStatusCode.Created, response.StatusCode);
        return await response.Content.ReadFromJsonAsync<JsonElement>();
    }
    private static async Task<JsonElement> Challenge(HttpClient anonymous, string email, Guid deviceId)
    {
        using var response = await anonymous.PostAsJsonAsync(Base + "/challenge", new { email, deviceId });
        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        return await response.Content.ReadFromJsonAsync<JsonElement>();
    }
    private static object Proof(JsonElement challenge, RSA key) => new { challengeToken = challenge.GetProperty("challengeToken").GetString(), signature = Convert.ToBase64String(key.SignData(Encoding.UTF8.GetBytes(challenge.GetProperty("payload").GetString()!), HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1)) };
    private sealed record UserSession(AppUser User, HttpClient Http) : IDisposable { public void Dispose() => Http.Dispose(); }
}
