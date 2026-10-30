using Microsoft.AspNetCore.Identity;
using Microsoft.EntityFrameworkCore;
using FruitVision.Api.Contracts;
using FruitVision.Api.Data;
using FruitVision.Api.Infrastructure;
using FruitVision.Api.Realtime;

namespace FruitVision.Api.Auth;

public static class AuthEndpoints
{
    public static void MapAuth(this WebApplication app)
    {
        var group=app.MapGroup("/api/v1/auth").AddEndpointFilter<InputFilter>().WithTags("Tài khoản");
        group.MapPost("/register",async(RegisterRequest r,UserManager<AppUser> users,AppDbContext db,LocationDirectory locations,EmailOtpService otp,HttpContext http)=> {
            if(!Input.Safe(r.DisplayName)||!Input.Safe(r.Email)) return Input.Invalid("Thông tin chứa ký tự điều khiển.");
            if(!otp.IsReady) return EmailOtpService.Unavailable();
            var location=await locations.ValidateAsync(r.CountryCode,r.ProvinceCode,http.RequestAborted);
            if(location.Region.Length>120)return Input.Invalid("Tên khu vực quá dài; vui lòng chọn một địa điểm khác hoặc liên hệ quản trị.");
            var user=new AppUser{Id=Guid.NewGuid(),Email=Input.Text(r.Email),UserName=Input.Text(r.Email),
                DisplayName=Input.Text(r.DisplayName),Region=location.Region,CountryCode=location.CountryCode,ProvinceCode=location.ProvinceCode,Role=AccountRole.Consumer,
                ApprovalStatus=ApprovalState.Approved,EmailConfirmed=false,LockoutEnabled=true};
            var result=await users.CreateAsync(user,r.Password);
            if(!result.Succeeded) return Results.ValidationProblem(new Dictionary<string,string[]>{{"registration",result.Errors.Select(x=>x.Code).ToArray()}});
            db.AuditEntries.Add(SessionTokens.Audit(user.Id,user.Id,"AccountRegistered"));
            await db.SaveChangesAsync();
            return await otp.StartAsync(user,db,http,"register",registration:true);
        }).RequireRateLimiting("auth");

        group.MapPost("/login",async(LoginRequest r,UserManager<AppUser> users,AppDbContext db,EmailOtpService otp,HttpContext http)=> {
            var user=await users.FindByEmailAsync(Input.Text(r.Email));
            if(user is null || !user.IsActive || await users.IsLockedOutAsync(user)) return BadLogin();
            if(!await users.CheckPasswordAsync(user,r.Password)) {await users.AccessFailedAsync(user);return BadLogin();}
            await users.ResetAccessFailedCountAsync(user);
            if(user.TwoFactorEnabled) {
                var token=SessionTokens.New();
                db.LoginChallenges.Add(new LoginChallenge{Hash=SessionTokens.Hash(token),UserId=user.Id,SecurityStamp=user.SecurityStamp ?? "",ExpiresAt=DateTimeOffset.UtcNow.AddMinutes(5)});
                await db.SaveChangesAsync();
                return Results.Ok(new {requiresTwoFactor=true,method="authenticator",challengeToken=token,expiresIn=300});
            }
            if(otp.RequiredOnLogin||!user.EmailConfirmed)return await otp.StartAsync(user,db,http,"login");
            return await Issue(user,db);
        }).RequireRateLimiting("auth");

        group.MapPost("/mfa/login",async(MfaLoginRequest r,AppDbContext db,UserManager<AppUser> users)=> {
            if(!SessionTokens.Valid(r.ChallengeToken)) return BadLogin();
            await using var tx=await db.Database.BeginTransactionAsync();
            var hash=SessionTokens.Hash(r.ChallengeToken);
            var c=await db.LoginChallenges.FromSqlInterpolated($"SELECT * FROM \"LoginChallenges\" WHERE \"Hash\"={hash} FOR UPDATE").SingleOrDefaultAsync();
            if(c is null||c.Consumed||c.Attempts>=5||c.ExpiresAt<=DateTimeOffset.UtcNow) return BadLogin();
            var user=await users.FindByIdAsync(c.UserId.ToString());
            if(user is null||!user.IsActive||!user.TwoFactorEnabled||user.SecurityStamp!=c.SecurityStamp||await users.IsLockedOutAsync(user)) return BadLogin();
            c.Attempts++;
            if(!await users.VerifyTwoFactorTokenAsync(user,TokenOptions.DefaultAuthenticatorProvider,r.Code)) {
                await db.SaveChangesAsync();await tx.CommitAsync();return BadLogin();
            }
            c.Consumed=true;
            var output=await Issue(user,db,"password_totp");
            await tx.CommitAsync();return output;
        }).RequireRateLimiting("auth");

        group.MapPost("/refresh",async(RefreshRequest r,AppDbContext db,SessionConnections connections)=> {
            if(!SessionTokens.Valid(r.RefreshToken)) return BadLogin();
            var hash=SessionTokens.Hash(r.RefreshToken);
            await using var tx=await db.Database.BeginTransactionAsync();
            var s=await db.AuthSessions.FromSqlInterpolated($"SELECT * FROM \"AuthSessions\" WHERE \"RefreshHash\"={hash} FOR UPDATE").SingleOrDefaultAsync();
            if(s is null) {
                var consumed=await db.ConsumedRefreshes.FindAsync(hash);
                if(consumed is not null) {
                    await db.AuthSessions.Where(x=>x.Id==consumed.SessionId).ExecuteUpdateAsync(x=>x.SetProperty(v=>v.RevokedAt,DateTimeOffset.UtcNow));
                    connections.AbortSession(consumed.SessionId);
                    db.AuditEntries.Add(SessionTokens.Audit(null,null,"RefreshTokenReplay","Session family revoked"));
                    await db.SaveChangesAsync();await tx.CommitAsync();
                }
                return BadLogin();
            }
            var u=await db.Users.SingleAsync(x=>x.Id==s.UserId);
            if(s.RevokedAt is not null||s.RefreshExpiresAt<=DateTimeOffset.UtcNow||!u.IsActive||s.SecurityStamp!=u.SecurityStamp||u.LockoutEnd>DateTimeOffset.UtcNow) return BadLogin();
            db.ConsumedRefreshes.Add(new ConsumedRefresh{Hash=hash,SessionId=s.Id,ExpiresAt=s.RefreshExpiresAt});
            var access=SessionTokens.New();var refresh=SessionTokens.New();
            s.AccessHash=SessionTokens.Hash(access);s.RefreshHash=SessionTokens.Hash(refresh);s.AccessExpiresAt=DateTimeOffset.UtcNow.AddMinutes(15);
            await db.SaveChangesAsync();await tx.CommitAsync();
            return Results.Ok(SessionTokens.Response(u,s,access,refresh));
        }).RequireRateLimiting("auth");

        group.MapGet("/me",async(HttpContext http,AppDbContext db)=>Results.Ok(SessionTokens.Profile(await db.Users.SingleAsync(x=>x.Id==http.User.UserId())))).RequireAuthorization();
        group.MapPost("/logout",async(HttpContext http,AppDbContext db,SessionConnections connections)=> {
            var id=http.User.SessionId();
            await db.AuthSessions.Where(x=>x.Id==id).ExecuteUpdateAsync(x=>x.SetProperty(v=>v.RevokedAt,DateTimeOffset.UtcNow));
            connections.AbortSession(id);return Results.NoContent();
        }).RequireAuthorization();
        group.MapGet("/sessions",async(HttpContext http,AppDbContext db)=> {
            var uid=http.User.UserId();
            return Results.Ok(new {items=await db.AuthSessions.AsNoTracking().Where(x=>x.UserId==uid&&x.RevokedAt==null&&x.RefreshExpiresAt>DateTimeOffset.UtcNow)
                .OrderByDescending(x=>x.CreatedAt).Take(50).Select(x=>new{x.Id,x.CreatedAt,x.AccessExpiresAt,current=x.Id==http.User.SessionId()}).ToListAsync()});
        }).RequireAuthorization();
        group.MapDelete("/sessions/{id:guid}",async(Guid id,HttpContext http,AppDbContext db,SessionConnections connections)=> {
            var changed=await db.AuthSessions.Where(x=>x.Id==id&&x.UserId==http.User.UserId()).ExecuteUpdateAsync(x=>x.SetProperty(v=>v.RevokedAt,DateTimeOffset.UtcNow));
            if(changed==0)return Results.NotFound();connections.AbortSession(id);return Results.NoContent();
        }).RequireAuthorization();

        group.MapPost("/mfa/setup",async(PasswordRequest r,HttpContext http,AppDbContext db,UserManager<AppUser> users,SessionConnections connections)=> {
            var user=await db.Users.SingleAsync(x=>x.Id==http.User.UserId());
            if(!await users.CheckPasswordAsync(user,r.Password)) return BadLogin();
            if(user.TwoFactorEnabled)return Results.Conflict(new{message="MFA đã được bật."});
            if(await users.GetAuthenticatorKeyAsync(user) is null) {
                var reset=await users.ResetAuthenticatorKeyAsync(user);
                if(!reset.Succeeded)return Input.Invalid("Không thể tạo khóa xác thực.");
                // Identity rotates the security stamp when creating a key. Preserve
                // only this password-reauthenticated session so enrollment can finish.
                var sid=http.User.SessionId();
                await db.AuthSessions.Where(x=>x.Id==sid).ExecuteUpdateAsync(x=>x.SetProperty(v=>v.SecurityStamp,user.SecurityStamp!));
                await db.AuthSessions.Where(x=>x.UserId==user.Id&&x.Id!=sid).ExecuteUpdateAsync(x=>x.SetProperty(v=>v.RevokedAt,DateTimeOffset.UtcNow));
                connections.AbortUser(user.Id);
            }
            var key=await users.GetAuthenticatorKeyAsync(user);
            return Results.Ok(new{sharedKey=key,authenticatorUri=$"otpauth://totp/FruitVision:{Uri.EscapeDataString(user.Email!)}?secret={key}&issuer=FruitVision&digits=6"});
        }).RequireAuthorization().RequireRateLimiting("auth");
        group.MapPost("/mfa/enable",async(MfaCodeRequest r,HttpContext http,AppDbContext db,UserManager<AppUser> users,SessionConnections connections)=> {
            var user=await db.Users.SingleAsync(x=>x.Id==http.User.UserId());
            if(user.TwoFactorEnabled)return Results.Conflict();
            if(!await users.VerifyTwoFactorTokenAsync(user,TokenOptions.DefaultAuthenticatorProvider,r.Code)) return Input.Invalid("Mã xác thực không đúng.");
            await users.SetTwoFactorEnabledAsync(user,true);
            await db.AuthSessions.Where(x=>x.UserId==user.Id).ExecuteUpdateAsync(x=>x.SetProperty(v=>v.RevokedAt,DateTimeOffset.UtcNow));
            db.AuditEntries.Add(SessionTokens.Audit(user.Id,user.Id,"MfaEnabled"));await db.SaveChangesAsync();
            connections.AbortUser(user.Id);return Results.Ok(new{message="Đã bật MFA; hãy đăng nhập lại bằng mã xác thực."});
        }).RequireAuthorization().RequireRateLimiting("auth");
    }

    private static IResult BadLogin()=>Results.Problem(statusCode:401,title:"Không thể xác thực thông tin đăng nhập hoặc phiên.");
    internal static async Task<IResult> Issue(AppUser u,AppDbContext db,string authMethod="password")
    {
        var(s,access,refresh)=SessionTokens.Create(u,authMethod);db.AuthSessions.Add(s);
        db.AuditEntries.Add(SessionTokens.Audit(u.Id,u.Id,"LoginSucceeded"));await db.SaveChangesAsync();
        return Results.Ok(SessionTokens.Response(u,s,access,refresh));
    }
}
