using System.ComponentModel.DataAnnotations;
using System.Security.Cryptography;
using System.Text.Json;
using FruitVision.Api.Contracts;
using FruitVision.Api.Data;
using FruitVision.Api.Infrastructure;
using Microsoft.AspNetCore.DataProtection;
using Microsoft.AspNetCore.Identity;
using Microsoft.EntityFrameworkCore;

namespace FruitVision.Api.Contracts
{
    public sealed record FaceImageRequest([property: Required, StringLength(FruitVision.Api.Auth.FaceEngine.MaximumImageCharacters)] string ImageBase64);
    public sealed record FaceLoginRequest([property: Required, EmailAddress, StringLength(254)] string Email,
        [property: Required, StringLength(FruitVision.Api.Auth.FaceEngine.MaximumImageCharacters)] string ImageBase64);
}

namespace FruitVision.Api.Auth
{
    public static class FaceAuthEndpoints
    {
        public static void MapFaceAuth(this WebApplication app)
        {
            app.MapGet("/api/v1/auth/face/status", async (HttpContext http, AppDbContext db, IFaceEngine engine, EmailOtpService otp, CancellationToken ct) =>
                Results.Ok(new { enrolled = await db.Set<FaceIdentity>().AsNoTracking().AnyAsync(face => face.UserId == http.User.UserId() && face.ModelSha256 == FaceEngine.ModelSha256, ct),
                    ready = engine.IsReady && otp.IsReady, livenessVerified = false })).RequireAuthorization();
            app.MapPost("/api/v1/auth/face/enroll", Enroll).RequireAuthorization().AddEndpointFilter<InputFilter>();
            app.MapDelete("/api/v1/auth/face", Revoke).RequireAuthorization();
            app.MapPost("/api/v1/auth/face/login", Login).AllowAnonymous().RequireRateLimiting("auth").AddEndpointFilter<InputFilter>();
        }
        private static IDataProtector Protector(IDataProtectionProvider provider, Guid id) =>
            provider.CreateProtector("FruitVision.Face.v1").CreateProtector(id.ToString("D"));
        private static bool CanLogin(AppUser? user, DateTimeOffset now) => user is { IsActive: true, EmailConfirmed: true } && !(user.LockoutEnd > now);
        private static IResult FreshRequired() => Results.Problem(statusCode: 403, title: "Đăng nhập lại bằng mật khẩu và mã email/TOTP trước khi quản lý khuôn mặt.");
        private static IResult InvalidLogin() => Results.Problem(statusCode: 401, title: "Không xác thực được thông tin đăng nhập.");
        private static IResult EngineFailure(FaceEngineException error, HttpContext http)
        {
            if (error.StatusCode == 429) http.Response.Headers.RetryAfter = "3";
            return Results.Problem(statusCode: error.StatusCode, title: "Chưa xử lý được ảnh khuôn mặt; hãy kiểm tra ảnh hoặc thử lại sau.",
                extensions: new Dictionary<string, object?> { ["code"] = error.Code, ["livenessVerified"] = false });
        }
        private static bool ImageValid(string value)
        {
            if (value.Length is < 24 or > FaceEngine.MaximumImageCharacters) return false;
            byte[] bytes;
            try { bytes = Convert.FromBase64String(value); } catch (FormatException) { return false; }
            try
            {
                return bytes.Length is >= 16 and <= 2097152 && Convert.ToBase64String(bytes) == value &&
                    ((bytes[0] == 255 && bytes[1] == 216 && bytes[2] == 255) || bytes.AsSpan(0, 8).SequenceEqual(new byte[] { 137, 80, 78, 71, 13, 10, 26, 10 }));
            }
            finally { CryptographicOperations.ZeroMemory(bytes); }
        }
        private static async Task<bool> Fresh(AppDbContext db, HttpContext http, AppUser? user, CancellationToken ct)
        {
            var now = DateTimeOffset.UtcNow;
            if (!CanLogin(user, now)) return false;
            var sid = http.User.SessionId();
            return await db.AuthSessions.AsNoTracking().AnyAsync(session => session.Id == sid && session.UserId == user!.Id &&
                session.RevokedAt == null && session.SecurityStamp == (user.SecurityStamp ?? "") && session.AccessExpiresAt > now &&
                session.CreatedAt <= now && session.CreatedAt >= now.AddMinutes(-15) &&
                (session.AuthMethod == "password_email_otp" || session.AuthMethod == "password_totp"), ct);
        }
        private static Task<AppUser?> LockUser(AppDbContext db, Guid id, CancellationToken ct) =>
            db.Users.FromSqlInterpolated($"SELECT * FROM \"AspNetUsers\" WHERE \"Id\"={id} FOR UPDATE").SingleOrDefaultAsync(ct);
        private static Task InvalidateChallenges(AppDbContext db, Guid id, CancellationToken ct) =>
            db.Set<EmailOtpChallenge>().Where(challenge => challenge.UserId == id && challenge.Purpose == "face_login" && !challenge.Consumed)
                .ExecuteUpdateAsync(set => set.SetProperty(challenge => challenge.Consumed, true), ct);

        private static async Task<IResult> Enroll(FaceImageRequest request, HttpContext http, AppDbContext db, IFaceEngine engine,
            IDataProtectionProvider protection, EmailOtpService otp, CancellationToken ct)
        {
            var id = http.User.UserId();
            var initial = await db.Users.AsNoTracking().SingleOrDefaultAsync(user => user.Id == id, ct);
            if (!await Fresh(db, http, initial, ct)) return FreshRequired();
            if (!ImageValid(request.ImageBase64)) return EngineFailure(new(422, "FACE_IMAGE_INVALID"), http);
            if (!engine.IsReady) return EngineFailure(new(503, "FACE_SERVICE_UNAVAILABLE"), http);
            double[] embedding;
            try { embedding = FaceEngine.Normalize(await engine.ExtractAsync(request.ImageBase64, ct)); }
            catch (FaceEngineException error) { return EngineFailure(error, http); }
            try
            {
                await using var tx = await db.Database.BeginTransactionAsync(ct);
                var user = await LockUser(db, id, ct);
                if (!await Fresh(db, http, user, ct)) return FreshRequired();
                var identity = await db.Set<FaceIdentity>().SingleOrDefaultAsync(face => face.UserId == id, ct);
                var created = identity is null;
                if (created) { identity = new FaceIdentity { UserId = id }; db.Add(identity); }
                identity!.ProtectedEmbedding = Protector(protection, id).Protect(JsonSerializer.Serialize(embedding));
                identity.ModelSha256 = FaceEngine.ModelSha256; identity.UpdatedAt = DateTimeOffset.UtcNow;
                await InvalidateChallenges(db, id, ct);
                db.AuditEntries.Add(SessionTokens.Audit(id, id, created ? "FaceEnrolled" : "FaceReenrolled", FaceEngine.ModelSha256));
                await db.SaveChangesAsync(ct); await tx.CommitAsync(ct);
                var view = new { enrolled = true, ready = engine.IsReady && otp.IsReady, livenessVerified = false, updatedAt = identity.UpdatedAt };
                return created ? Results.Created("/api/v1/auth/face/status", view) : Results.Ok(view);
            }
            finally { Array.Clear(embedding); }
        }
        private static async Task<IResult> Revoke(HttpContext http, AppDbContext db, CancellationToken ct)
        {
            var id = http.User.UserId(); await using var tx = await db.Database.BeginTransactionAsync(ct);
            var user = await LockUser(db, id, ct);
            if (!await Fresh(db, http, user, ct)) return FreshRequired();
            var identity = await db.Set<FaceIdentity>().SingleOrDefaultAsync(face => face.UserId == id, ct);
            if (identity is not null) db.Remove(identity);
            await InvalidateChallenges(db, id, ct);
            db.AuditEntries.Add(SessionTokens.Audit(id, id, "FaceRevoked"));
            await db.SaveChangesAsync(ct); await tx.CommitAsync(ct);
            return Results.NoContent();
        }
        private static async Task<IResult> Login(FaceLoginRequest request, HttpContext http, AppDbContext db, IFaceEngine engine,
            IDataProtectionProvider protection, UserManager<AppUser> users, EmailOtpService otp, CancellationToken ct)
        {
            if (!ImageValid(request.ImageBase64)) return EngineFailure(new(422, "FACE_IMAGE_INVALID"), http);
            var user = await users.FindByEmailAsync(Input.Text(request.Email));
            if (!CanLogin(user, DateTimeOffset.UtcNow) || user!.TwoFactorEnabled) return InvalidLogin();
            var identity = await db.Set<FaceIdentity>().AsNoTracking().SingleOrDefaultAsync(face => face.UserId == user.Id && face.ModelSha256 == FaceEngine.ModelSha256, ct);
            if (identity is null) return InvalidLogin();
            if (!engine.IsReady) return EngineFailure(new(503, "FACE_SERVICE_UNAVAILABLE"), http);
            double[] stored;
            try { stored = FaceEngine.Normalize(JsonSerializer.Deserialize<double[]>(Protector(protection, user.Id).Unprotect(identity.ProtectedEmbedding)) ?? []); }
            catch (Exception error) when (error is CryptographicException or JsonException or FaceEngineException) { return InvalidLogin(); }
            double[]? probe = null;
            try
            {
                try { probe = FaceEngine.Normalize(await engine.ExtractAsync(request.ImageBase64, ct)); }
                catch (FaceEngineException error) { return EngineFailure(error, http); }
                var score = Math.Clamp(stored.Zip(probe).Sum(pair => pair.First * pair.Second), -1, 1);
                if (score < .363) { await users.AccessFailedAsync(user); return InvalidLogin(); }
                // StartAsync reloads/locks User, enforces confirmed email/no TOTP and binds this exact template snapshot.
                // Rotation/revocation takes the same User lock and consumes pending face_login challenges.
                return await otp.StartAsync(user, db, http, "face_login", expectedFaceTemplate: identity.ProtectedEmbedding);
            }
            finally { Array.Clear(stored); if (probe is not null) Array.Clear(probe); }
        }
    }
}
