using System.ComponentModel.DataAnnotations;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using FruitVision.Api.Contracts;
using FruitVision.Api.Data;
using FruitVision.Api.Infrastructure;
using FruitVision.Api.Realtime;
using Microsoft.AspNetCore.Identity;
using Microsoft.EntityFrameworkCore;

namespace FruitVision.Api.Contracts
{
    public sealed record EnrollBiometricDeviceRequest(Guid DeviceId,
        [property: Required, StringLength(100, MinimumLength = 2)] string Label,
        [property: Required, StringLength(2048, MinimumLength = 4)] string PublicKey);
    public sealed record DeviceBiometricChallengeRequest(
        [property: Required, EmailAddress, StringLength(254)] string Email, Guid DeviceId);
    public sealed record DeviceBiometricLoginRequest(
        [property: Required, StringLength(43, MinimumLength = 43)] string ChallengeToken,
        [property: Required, StringLength(1024, MinimumLength = 4)] string Signature);
}

namespace FruitVision.Api.Auth
{
    public static class DeviceBiometricEndpoints
    {
        public static void MapDeviceBiometrics(this WebApplication app)
        {
            var devices = app.MapGroup("/api/v1/auth/biometric/devices").RequireAuthorization().AddEndpointFilter<InputFilter>().WithTags("Thiết bị sinh trắc học");
            devices.MapGet("", List);
            devices.MapPost("", Enroll);
            devices.MapDelete("/{id:guid}", Revoke);
            var login = app.MapGroup("/api/v1/auth/biometric").RequireRateLimiting("auth").AddEndpointFilter<InputFilter>().WithTags("Đăng nhập bằng khóa thiết bị");
            login.MapPost("/challenge", Challenge).AllowAnonymous();
            login.MapPost("/login", Login).AllowAnonymous();
        }

        private static bool CanLogin(AppUser? user, DateTimeOffset now) => user is { IsActive: true, EmailConfirmed: true } && !(user.LockoutEnd > now);
        private static Task<AppUser?> LockUser(AppDbContext db, Guid id, CancellationToken ct) =>
            db.Users.FromSqlInterpolated($"SELECT * FROM \"AspNetUsers\" WHERE \"Id\"={id} FOR UPDATE").SingleOrDefaultAsync(ct);
        private static object View(BiometricDevice device) => new { device.Id, device.DeviceId, device.Label, device.CreatedAt, device.LastUsedAt, device.RevokedAt };
        private static string KeyHash(string key) => Convert.ToHexString(SHA256.HashData(Convert.FromBase64String(key)));

        private static byte[] Base64(string input, int maximum)
        {
            if (input.Length is < 4 || input.Length > maximum || input.Any(c => !char.IsAsciiLetterOrDigit(c) && c is not ('+' or '/' or '=')))
                throw new FormatException("Invalid base64.");
            return Convert.FromBase64String(input);
        }
        private static string PublicKey(string input)
        {
            var bytes = Base64(input, 2048);
            using var rsa = RSA.Create();
            rsa.ImportSubjectPublicKeyInfo(bytes, out var read);
            if (read != bytes.Length || rsa.KeySize is < 2048 or > 4096) throw new CryptographicException("Unsupported public key.");
            return Convert.ToBase64String(rsa.ExportSubjectPublicKeyInfo());
        }
        private static bool Verify(string key, string payload, string signature)
        {
            try
            {
                using var rsa = RSA.Create();
                var bytes = Base64(key, 2048);
                rsa.ImportSubjectPublicKeyInfo(bytes, out var read);
                var proof = Base64(signature, 1024);
                return read == bytes.Length && rsa.KeySize is >= 2048 and <= 4096 && proof.Length == rsa.KeySize / 8 &&
                    rsa.VerifyData(Encoding.UTF8.GetBytes(payload), proof, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
            }
            catch (Exception exception) when (exception is CryptographicException or FormatException or ArgumentException) { return false; }
        }

        private static async Task<IResult> List(HttpContext http, AppDbContext db, CancellationToken ct)
        {
            var uid = http.User.UserId();
            var rows = await db.Set<BiometricDevice>().AsNoTracking().Where(device => device.UserId == uid)
                .OrderByDescending(device => device.CreatedAt).ThenBy(device => device.Id).ToListAsync(ct);
            return Results.Ok(new { items = rows.Select(View) });
        }

        private static async Task Invalidate(AppDbContext db, Guid deviceId, DateTimeOffset now, CancellationToken ct)
        {
            await db.Set<BiometricChallenge>().Where(challenge => challenge.CredentialId == deviceId && challenge.ConsumedAt == null)
                .ExecuteUpdateAsync(setters => setters.SetProperty(challenge => challenge.ConsumedAt, now), ct);
            await db.AuthSessions.Where(session => session.BiometricDeviceId == deviceId && session.RevokedAt == null)
                .ExecuteUpdateAsync(setters => setters.SetProperty(session => session.RevokedAt, now), ct);
        }

        private static async Task<IResult> Enroll(EnrollBiometricDeviceRequest request, HttpContext http, AppDbContext db, SessionConnections connections, CancellationToken ct)
        {
            await using var tx = await db.Database.BeginTransactionAsync(ct);
            var user = await LockUser(db, http.User.UserId(), ct);
            var now = DateTimeOffset.UtcNow;
            if (!CanLogin(user, now)) return Input.Denied();
            var sessionId = http.User.SessionId();
            var session = await db.AuthSessions.AsNoTracking().SingleOrDefaultAsync(s => s.Id == sessionId && s.UserId == user!.Id, ct);
            if (session is null || session.RevokedAt is not null || session.SecurityStamp != (user!.SecurityStamp ?? "") || session.AccessExpiresAt <= now || session.CreatedAt > now ||
                session.CreatedAt < now.AddMinutes(-15) || session.AuthMethod is not ("password_email_otp" or "password_totp"))
                return Results.Problem(statusCode: 403, title: "Đăng nhập lại bằng mật khẩu và mã xác minh trước khi quản lý khóa thiết bị.");
            if (request.DeviceId == Guid.Empty || !Input.Safe(request.Label) || Input.Text(request.Label).Length < 2) return Input.Invalid("Tên hoặc mã thiết bị không hợp lệ.");
            string key;
            try { key = PublicKey(request.PublicKey); }
            catch (Exception exception) when (exception is CryptographicException or FormatException or ArgumentException) { return Input.Invalid("Cần khóa công khai RSA SPKI từ 2048 đến 4096 bit."); }
            var device = await db.Set<BiometricDevice>().SingleOrDefaultAsync(d => d.UserId == user!.Id && d.DeviceId == request.DeviceId, ct);
            if ((device is null || device.RevokedAt is not null) && await db.Set<BiometricDevice>().CountAsync(d => d.UserId == user!.Id && d.RevokedAt == null, ct) >= 10) return Results.Conflict();
            var created = device is null;
            if (created) { device = new() { UserId = user!.Id, DeviceId = request.DeviceId }; db.Add(device); }
            else await Invalidate(db, device!.Id, now, ct);
            device!.Label = Input.Text(request.Label); device.PublicKey = key; device.RevokedAt = null;
            db.AuditEntries.Add(SessionTokens.Audit(user!.Id, user.Id, created ? "BiometricDeviceEnrolled" : "BiometricDeviceRotated", device.Id.ToString()));
            await db.SaveChangesAsync(ct);
            var view = View(device);
            await tx.CommitAsync(ct);
            if (!created) connections.AbortUser(user.Id);
            return created ? Results.Created($"/api/v1/auth/biometric/devices/{device.Id}", view) : Results.Ok(view);
        }

        private static async Task<IResult> Revoke(Guid id, HttpContext http, AppDbContext db, SessionConnections connections, CancellationToken ct)
        {
            await using var tx = await db.Database.BeginTransactionAsync(ct);
            var uid = http.User.UserId();
            await LockUser(db, uid, ct);
            var device = await db.Set<BiometricDevice>().SingleOrDefaultAsync(d => d.Id == id && d.UserId == uid, ct);
            if (device is null) return Results.NotFound();
            var now = DateTimeOffset.UtcNow;
            await Invalidate(db, device.Id, now, ct);
            if (device.RevokedAt is null)
            {
                device.RevokedAt = now;
                db.AuditEntries.Add(SessionTokens.Audit(uid, uid, "BiometricDeviceRevoked", device.Id.ToString()));
            }
            await db.SaveChangesAsync(ct);
            await tx.CommitAsync(ct);
            connections.AbortUser(uid);
            return Results.NoContent();
        }

        private static async Task<IResult> Challenge(DeviceBiometricChallengeRequest request, AppDbContext db, UserManager<AppUser> users, CancellationToken ct)
        {
            var email = users.NormalizeEmail(request.Email.Trim());
            var userId = await db.Users.AsNoTracking().Where(u => u.NormalizedEmail == email).Select(u => (Guid?)u.Id).SingleOrDefaultAsync(ct);
            if (!userId.HasValue || request.DeviceId == Guid.Empty) return Results.Unauthorized();
            await using var tx = await db.Database.BeginTransactionAsync(ct);
            var user = await LockUser(db, userId.Value, ct);
            var now = DateTimeOffset.UtcNow;
            if (!CanLogin(user, now)) return Results.Unauthorized();
            var device = await db.Set<BiometricDevice>().AsNoTracking().SingleOrDefaultAsync(d => d.UserId == userId && d.DeviceId == request.DeviceId && d.RevokedAt == null, ct);
            if (device is null) return Results.Unauthorized();
            var token = SessionTokens.New();
            var expiry = DateTimeOffset.FromUnixTimeSeconds(now.AddMinutes(2).ToUnixTimeSeconds());
            var payload = JsonSerializer.Serialize(new { issuer = "FruitVision", userId = user!.Id, deviceId = device.DeviceId, nonce = SessionTokens.New(), expiresAt = expiry.ToUnixTimeSeconds() });
            db.Add(new BiometricChallenge { Hash = SessionTokens.Hash(token), UserId = user!.Id, CredentialId = device.Id,
                CredentialPublicKeyHash = KeyHash(device.PublicKey), SecurityStamp = user.SecurityStamp ?? "", Payload = payload, ExpiresAt = expiry });
            await db.SaveChangesAsync(ct);
            await tx.CommitAsync(ct);
            return Results.Ok(new { challengeToken = token, payload, expiresAt = expiry });
        }

        private static async Task<IResult> Login(DeviceBiometricLoginRequest request, AppDbContext db, CancellationToken ct)
        {
            if (!SessionTokens.Valid(request.ChallengeToken)) return Results.Unauthorized();
            var hash = SessionTokens.Hash(request.ChallengeToken);
            var subject = await db.Set<BiometricChallenge>().AsNoTracking().Where(c => c.Hash == hash).Select(c => (Guid?)c.UserId).SingleOrDefaultAsync(ct);
            if (!subject.HasValue) return Results.Unauthorized();
            await using var tx = await db.Database.BeginTransactionAsync(ct);
            var user = await LockUser(db, subject.Value, ct);
            var challenge = await db.Set<BiometricChallenge>().FromSqlInterpolated($"SELECT * FROM \"BiometricChallenges\" WHERE \"Hash\"={hash} FOR UPDATE").SingleOrDefaultAsync(ct);
            if (challenge is null || challenge.ConsumedAt is not null) return Results.Unauthorized();
            var now = DateTimeOffset.UtcNow;
            challenge.ConsumedAt = now;
            var device = await db.Set<BiometricDevice>().SingleOrDefaultAsync(d => d.Id == challenge.CredentialId && d.UserId == subject.Value, ct);
            var valid = CanLogin(user, now) && challenge.ExpiresAt > now && challenge.SecurityStamp == user!.SecurityStamp && device is { RevokedAt: null } &&
                challenge.CredentialPublicKeyHash == KeyHash(device.PublicKey) && Verify(device.PublicKey, challenge.Payload, request.Signature);
            if (!valid)
            {
                await db.SaveChangesAsync(ct);
                await tx.CommitAsync(ct);
                return Results.Unauthorized();
            }
            var (session, access, refresh) = SessionTokens.Create(user!, "device_biometric");
            session.BiometricDeviceId = device!.Id;
            device.LastUsedAt = now;
            db.AuthSessions.Add(session);
            db.AuditEntries.Add(SessionTokens.Audit(user!.Id, user.Id, "BiometricLogin", device.Id.ToString()));
            await db.SaveChangesAsync(ct);
            var response = SessionTokens.Response(user, session, access, refresh);
            await tx.CommitAsync(ct);
            return Results.Ok(response);
        }
    }
}
