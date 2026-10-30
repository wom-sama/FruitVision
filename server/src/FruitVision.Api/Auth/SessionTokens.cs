using System.Security.Claims;
using System.Security.Cryptography;
using System.Text;
using System.Text.Encodings.Web;
using Microsoft.AspNetCore.Authentication;
using Microsoft.AspNetCore.WebUtilities;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Options;
using FruitVision.Api.Data;

namespace FruitVision.Api.Auth;

public static class SessionTokens
{
    public static string New() => WebEncoders.Base64UrlEncode(RandomNumberGenerator.GetBytes(32));
    public static bool Valid(string? token) => token is { Length: 43 } && token.All(c => char.IsAsciiLetterOrDigit(c) || c is '-' or '_');
    public static string Hash(string value) => Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(value)));
    public static Guid UserId(this ClaimsPrincipal user) => Guid.Parse(user.FindFirstValue(ClaimTypes.NameIdentifier)!);
    public static Guid SessionId(this ClaimsPrincipal user) => Guid.Parse(user.FindFirstValue("session_id")!);
    public static object Profile(AppUser u) => new {u.Id,u.DisplayName,u.Email,role=u.Role.ToString(),approvalStatus=u.ApprovalStatus.ToString(),u.Region,u.IsActive,u.ReviewReason,twoFactorEnabled=u.TwoFactorEnabled};
    public static (AuthSession Session,string Access,string Refresh) Create(AppUser user)
    {
        var access=New();var refresh=New();
        return (new AuthSession {UserId=user.Id,AccessHash=Hash(access),RefreshHash=Hash(refresh),
            SecurityStamp=user.SecurityStamp ?? "",AccessExpiresAt=DateTimeOffset.UtcNow.AddMinutes(15),
            RefreshExpiresAt=DateTimeOffset.UtcNow.AddDays(7)}, access,refresh);
    }
    public static object Response(AppUser user,AuthSession s,string access,string refresh) => new {
        tokenType="Bearer",accessToken=access,refreshToken=refresh,expiresIn=Math.Max(0,(int)(s.AccessExpiresAt-DateTimeOffset.UtcNow).TotalSeconds),
        user=Profile(user)};
    public static AuditEntry Audit(Guid? actor,Guid? subject,string action,string reason="") =>
        new() {ActorId=actor,SubjectId=subject,Action=action,Reason=reason};
}

public class SessionAuthenticationHandler(IOptionsMonitor<AuthenticationSchemeOptions> options,ILoggerFactory logger,
    UrlEncoder encoder,AppDbContext db) : AuthenticationHandler<AuthenticationSchemeOptions>(options,logger,encoder)
{
    protected override async Task<AuthenticateResult> HandleAuthenticateAsync()
    {
        string? raw=null;
        var header=Request.Headers.Authorization.ToString();
        if(header.StartsWith("Bearer ",StringComparison.OrdinalIgnoreCase)) raw=header[7..];
        // SignalR browser transports cannot always supply an Authorization header.
        if(raw is null && Request.Path.StartsWithSegments("/hubs/fruitvision")) raw=Request.Query["access_token"];
        if(raw is null) return AuthenticateResult.NoResult();
        if(!SessionTokens.Valid(raw)) return AuthenticateResult.Fail("Invalid token");
        var hash=SessionTokens.Hash(raw);
        var now=DateTimeOffset.UtcNow;
        var session=await db.AuthSessions.AsNoTracking().Include(x=>x.User)
            .SingleOrDefaultAsync(x=>x.AccessHash==hash,Context.RequestAborted);
        if(session is null || session.RevokedAt is not null || session.AccessExpiresAt<=now || !session.User.IsActive ||
            session.SecurityStamp!=session.User.SecurityStamp || session.User.LockoutEnd>now)
            return AuthenticateResult.Fail("Session is no longer valid");
        var u=session.User;
        var claims=new[] {new Claim(ClaimTypes.NameIdentifier,u.Id.ToString()),new Claim(ClaimTypes.Name,u.DisplayName),
            new Claim(ClaimTypes.Role,u.Role.ToString()),new Claim("approval",u.ApprovalStatus.ToString()),
            new Claim("session_id",session.Id.ToString()),new Claim("access_exp",session.AccessExpiresAt.ToUnixTimeSeconds().ToString())};
        return AuthenticateResult.Success(new AuthenticationTicket(new ClaimsPrincipal(new ClaimsIdentity(claims,Scheme.Name)),
            new AuthenticationProperties{ExpiresUtc=session.AccessExpiresAt},Scheme.Name));
    }
}
