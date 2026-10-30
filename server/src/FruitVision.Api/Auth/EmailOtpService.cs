using System.Security.Cryptography;
using System.Text;
using FruitVision.Api.Data;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Options;

namespace FruitVision.Api.Auth;

public sealed class EmailOtpService(IEmailOtpMailer mailer, IOptions<EmailOtpOptions> options, ILogger<EmailOtpService> logger)
{
    public const string MailSubject = "Mã xác thực FruitVision";
    public bool IsReady => mailer.IsReady && Key() is not null;
    public bool RequiredOnLogin => options.Value.RequireOnPasswordLogin;
    private byte[]? Key()
    {
        try { var key = Convert.FromBase64String(options.Value.HashKey); return key.Length >= 32 ? key : null; }
        catch (FormatException) { return null; }
    }
    private string Recipient(AppUser user)
    {
        // A demo mapping is operator-owned and only applies to synthetic addresses, never arbitrary accounts.
        var email = user.Email!;
        return email.EndsWith("@fruitvision.test", StringComparison.OrdinalIgnoreCase) && options.Value.DemoRecipients.TryGetValue(email, out var mapped) ? mapped : email;
    }
    private string Hash(EmailOtpChallenge challenge, string code) => Convert.ToHexString(HMACSHA256.HashData(Key() ?? throw new InvalidOperationException("OTP key missing."),
        Encoding.UTF8.GetBytes(string.Join('\n', challenge.Hash, challenge.UserId, challenge.Recipient, challenge.Purpose, code))));
    public bool Matches(EmailOtpChallenge challenge, string code) => Key() is not null &&
        CryptographicOperations.FixedTimeEquals(Encoding.ASCII.GetBytes(Hash(challenge, code)), Encoding.ASCII.GetBytes(challenge.CodeHash));
    private static string Code() => RandomNumberGenerator.GetInt32(1_000_000).ToString("D6");
    public static IResult Unavailable() => Results.Problem(statusCode:503, title:"Chưa gửi được mã email. Vui lòng thử lại sau; chưa tạo phiên đăng nhập.");
    public static IResult Invalid() => Results.Problem(statusCode:401, title:"Mã hoặc phiên xác thực không hợp lệ, đã hết hạn hoặc đã được sử dụng.");
    private static IResult Cooldown(HttpContext http, int seconds)
    {
        http.Response.Headers.RetryAfter = seconds.ToString();
        return Results.Problem(statusCode:429, title:"Vui lòng chờ trước khi yêu cầu mã mới.", extensions:new Dictionary<string,object?> { ["retryAfter"] = seconds });
    }
    public object View(EmailOtpChallenge c, string token) => new {
        requiresTwoFactor = true, method = "email", challengeToken = token,
        expiresIn = Math.Max(0, (int)(c.ExpiresAt - DateTimeOffset.UtcNow).TotalSeconds),
        resendAfter = Math.Max(0, (int)Math.Ceiling(60 - (DateTimeOffset.UtcNow - c.SentAt).TotalSeconds)),
        emailHint = Mask(c.Recipient), mailSubject = MailSubject
    };
    private static string Mask(string recipient)
    {
        var i = recipient.IndexOf('@'); return i > 0 ? recipient[..1] + "***" + recipient[i..] : "***";
    }
    private async Task<bool> Send(EmailOtpChallenge c, string code, CancellationToken ct)
    {
        try { await mailer.SendAsync(c.Recipient, code, c.Purpose, ct); return true; }
        catch (Exception e) when (e is HttpRequestException or OperationCanceledException or InvalidOperationException or System.Text.Json.JsonException)
        { logger.LogWarning("Email OTP delivery unavailable ({Kind}); no session issued", e.GetType().Name); return false; }
    }
    public async Task<IResult> StartAsync(AppUser user, AppDbContext db, HttpContext http, string purpose, bool registration = false, string? expectedFaceTemplate = null)
    {
        if (!IsReady) return Unavailable();
        var expectedStamp = user.SecurityStamp;
        await using var tx = await db.Database.BeginTransactionAsync(http.RequestAborted);
        // All OTP writes lock User then Challenge; proof verification and resend use the same order.
        await db.Database.ExecuteSqlInterpolatedAsync($"SELECT 1 FROM \"AspNetUsers\" WHERE \"Id\"={user.Id} FOR UPDATE", http.RequestAborted);
        await db.Entry(user).ReloadAsync(http.RequestAborted);
        if (!user.IsActive || user.SecurityStamp != expectedStamp || user.LockoutEnd > DateTimeOffset.UtcNow) return Invalid();
        if (purpose == "face_login")
        {
            if (!user.EmailConfirmed || user.TwoFactorEnabled || expectedFaceTemplate is null) return Invalid();
            var current = await db.Set<FaceIdentity>().AsNoTracking().SingleOrDefaultAsync(t => t.UserId == user.Id,http.RequestAborted);
            if(current is null || current.ProtectedEmbedding != expectedFaceTemplate) return Invalid();
        }
        var now = DateTimeOffset.UtcNow;
        var lastSent = await db.Set<EmailOtpChallenge>().Where(c => c.UserId == user.Id).MaxAsync(c => (DateTimeOffset?)c.SentAt, http.RequestAborted);
        if (lastSent is { } last && now - last < TimeSpan.FromSeconds(60)) return Cooldown(http, (int)Math.Ceiling(60 - (now - last).TotalSeconds));
        var token = SessionTokens.New(); var code = Code();
        var challenge = new EmailOtpChallenge { Hash = SessionTokens.Hash(token), UserId = user.Id, SecurityStamp = user.SecurityStamp ?? "", Recipient = Recipient(user), Purpose = purpose, SentAt = now, ExpiresAt = now.AddMinutes(10) };
        challenge.CodeHash = Hash(challenge, code);
        if (!await Send(challenge, code, http.RequestAborted)) return Unavailable();
        // Supersede other challenges only after transport confirmed; never persist the plaintext code.
        await db.Set<EmailOtpChallenge>().Where(c => c.UserId == user.Id && !c.Consumed).ExecuteUpdateAsync(s => s.SetProperty(c => c.Consumed, true), http.RequestAborted);
        db.Add(challenge); await db.SaveChangesAsync(http.RequestAborted); await tx.CommitAsync(http.RequestAborted);
        if (!registration) return Results.Ok(View(challenge, token));
        return Results.Created("/api/v1/auth/me", new { requiresTwoFactor = true, method = "email", challengeToken = token,
            expiresIn = 600, resendAfter = 60, emailHint = Mask(challenge.Recipient), mailSubject = MailSubject, user = SessionTokens.Profile(user) });
    }
    public async Task<IResult> ResendAsync(string token, AppDbContext db, HttpContext http)
    {
        if (!SessionTokens.Valid(token)) return Invalid();
        if (!IsReady) return Unavailable();
        var hash = SessionTokens.Hash(token);
        var owner = await db.Set<EmailOtpChallenge>().AsNoTracking().Where(c => c.Hash == hash).Select(c => (Guid?)c.UserId).SingleOrDefaultAsync(http.RequestAborted);
        if (owner is null) return Invalid();
        await using var tx = await db.Database.BeginTransactionAsync(http.RequestAborted);
        var user = await db.Users.FromSqlInterpolated($"SELECT * FROM \"AspNetUsers\" WHERE \"Id\"={owner} FOR UPDATE").SingleAsync(http.RequestAborted);
        var c = await db.Set<EmailOtpChallenge>().FromSqlInterpolated($"SELECT * FROM \"EmailOtpChallenges\" WHERE \"Hash\"={hash} FOR UPDATE").SingleAsync(http.RequestAborted);
        if (!Valid(c, user) || c.SendCount >= 5) return Invalid();
        var seconds = 60 - (DateTimeOffset.UtcNow - c.SentAt).TotalSeconds;
        if (seconds > 0) return Cooldown(http, (int)Math.Ceiling(seconds));
        var code = Code(); while (Matches(c, code)) code = Code();
        if (!await Send(c, code, http.RequestAborted)) return Unavailable();
        c.CodeHash = Hash(c, code); c.SentAt = DateTimeOffset.UtcNow; c.ExpiresAt = c.SentAt.AddMinutes(10); c.SendCount++;
        // Wrong attempts never reset on resend, preventing an unlimited guessing budget.
        await db.SaveChangesAsync(http.RequestAborted); await tx.CommitAsync(http.RequestAborted);
        return Results.Ok(View(c, token));
    }
    public static bool Valid(EmailOtpChallenge c, AppUser user) => !c.Consumed && c.Attempts < 5 && c.ExpiresAt > DateTimeOffset.UtcNow &&
        user.IsActive && user.SecurityStamp == c.SecurityStamp && (user.LockoutEnd is null || user.LockoutEnd <= DateTimeOffset.UtcNow);
}
