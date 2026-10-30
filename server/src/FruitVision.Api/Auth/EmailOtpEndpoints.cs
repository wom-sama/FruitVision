using System.ComponentModel.DataAnnotations;
using FruitVision.Api.Data;
using FruitVision.Api.Infrastructure;
using Microsoft.EntityFrameworkCore;

namespace FruitVision.Api.Auth;

public sealed record VerifyEmailOtpRequest(
    [property:Required,StringLength(43,MinimumLength=43)] string ChallengeToken,
    [property:Required,RegularExpression("^[0-9]{6}$")] string Code);
public sealed record ResendEmailOtpRequest([property:Required,StringLength(43,MinimumLength=43)] string ChallengeToken);

public static class EmailOtpEndpoints
{
    public static void MapEmailOtp(this WebApplication app)
    {
        var group = app.MapGroup("/api/v1/auth").AddEndpointFilter<InputFilter>();
        group.MapGet("/methods", (EmailOtpService service,IFaceEngine face) => Results.Ok(new {
            emailOtpReady = service.IsReady, passwordLoginRequiresEmailOtp = service.RequiredOnLogin,
            emailOtpSubject = EmailOtpService.MailSubject, biometricReady = true, faceReady = face.IsReady && service.IsReady,
            faceLivenessVerified = false
        }));
        group.MapPost("/otp/resend", (ResendEmailOtpRequest r, AppDbContext db, HttpContext http, EmailOtpService service) =>
            service.ResendAsync(r.ChallengeToken, db, http)).RequireRateLimiting("auth");
        group.MapPost("/otp/verify", async (VerifyEmailOtpRequest r, AppDbContext db, HttpContext http, EmailOtpService service) =>
        {
            if (!SessionTokens.Valid(r.ChallengeToken)) return EmailOtpService.Invalid();
            var ct = http.RequestAborted; var hash = SessionTokens.Hash(r.ChallengeToken);
            var owner = await db.Set<EmailOtpChallenge>().AsNoTracking().Where(c => c.Hash == hash).Select(c => (Guid?)c.UserId).SingleOrDefaultAsync(ct);
            if (owner is null || !service.IsReady) return EmailOtpService.Invalid();
            await using var tx = await db.Database.BeginTransactionAsync(ct);
            var user = await db.Users.FromSqlInterpolated($"SELECT * FROM \"AspNetUsers\" WHERE \"Id\"={owner} FOR UPDATE").SingleAsync(ct);
            var challenge = await db.Set<EmailOtpChallenge>().FromSqlInterpolated($"SELECT * FROM \"EmailOtpChallenges\" WHERE \"Hash\"={hash} FOR UPDATE").SingleAsync(ct);
            if (!EmailOtpService.Valid(challenge, user)) return EmailOtpService.Invalid();
            if(challenge.Purpose=="face_login" && user.TwoFactorEnabled)return EmailOtpService.Invalid();
            challenge.Attempts++;
            if (!service.Matches(challenge, r.Code))
            {
                await db.SaveChangesAsync(ct); await tx.CommitAsync(ct); return EmailOtpService.Invalid();
            }
            challenge.Consumed = true; user.EmailConfirmed = true;
            var result = await AuthEndpoints.Issue(user, db, challenge.Purpose == "face_login" ? "face_email_otp" : "password_email_otp");
            await tx.CommitAsync(ct); return result;
        }).RequireRateLimiting("auth");
    }
}
