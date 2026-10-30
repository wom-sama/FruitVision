using FruitVision.Api.Auth;
using FruitVision.Api.Ai;
using FruitVision.Api.Contracts;
using FruitVision.Api.Data;
using FruitVision.Api.Infrastructure;
using FruitVision.Api.Realtime;
using Microsoft.EntityFrameworkCore;

namespace FruitVision.Api.Features;

public static class AccountEndpoints
{
    public static void MapAccounts(this WebApplication app)
    {
        app.MapPost("/api/v1/applications/resubmit",async(ProfileRequest r,HttpContext http,AppDbContext db,LocationDirectory locations)=> {
            var u=await db.Users.SingleAsync(x=>x.Id==http.User.UserId());
            if(u.Role is not (AccountRole.Producer or AccountRole.Trader)||u.ApprovalStatus is not (ApprovalState.NeedsInformation or ApprovalState.Rejected))return Results.Conflict();
            if(!Input.Safe(r.DisplayName))return Input.Invalid("Thông tin chứa ký tự điều khiển.");
            var location=await locations.ValidateAsync(r.CountryCode,r.ProvinceCode,http.RequestAborted);
            if(location.Region.Length>120)return Input.Invalid("Tên khu vực vượt giới hạn.");
            u.DisplayName=Input.Text(r.DisplayName);u.Region=location.Region;u.CountryCode=location.CountryCode;u.ProvinceCode=location.ProvinceCode;u.ApprovalStatus=ApprovalState.Pending;u.ReviewReason=null;
            db.AuditEntries.Add(SessionTokens.Audit(u.Id,u.Id,"ApplicationResubmitted"));await db.SaveChangesAsync();return Results.Ok(SessionTokens.Profile(u));
        }).RequireAuthorization().AddEndpointFilter<InputFilter>();
        var admin=app.MapGroup("/api/v1/admin").RequireAuthorization("Admin").AddEndpointFilter<InputFilter>().WithTags("Quản trị");
        admin.MapGet("/applications",async(string? status,int? limit,Guid? after,AppDbContext db)=> {
            if(!Input.Page(limit,out var size))return Input.Invalid("limit phải từ 1 đến 50.");
            var q=db.Users.AsNoTracking().Where(x=>x.Role!=AccountRole.Admin);
            if(status is not null){if(!Enum.TryParse<ApprovalState>(status,false,out var s)||!Enum.IsDefined(s))return Input.Invalid("Trạng thái không hợp lệ.");q=q.Where(x=>x.ApprovalStatus==s);}
            if(after.HasValue)q=q.Where(x=>x.Id.CompareTo(after.Value)>0);
            var rows=await q.OrderBy(x=>x.Id).Take(size+1).ToListAsync();
            return Results.Ok(new{items=rows.Take(size).Select(SessionTokens.Profile),next=rows.Count>size?rows[size-1].Id:(Guid?)null});
        });
        admin.MapPost("/applications/{id:guid}/review",async(Guid id,ReviewRequest r,HttpContext http,AppDbContext db,SessionConnections connections)=> {
            if(r.Status==ApprovalState.Pending||!Enum.IsDefined(r.Status)||!Input.Safe(r.Reason))return Input.Invalid("Kết quả và lý do xét duyệt không hợp lệ.");
            await using var tx=await db.Database.BeginTransactionAsync();
            var u=await db.Users.FromSqlInterpolated($"SELECT * FROM \"AspNetUsers\" WHERE \"Id\"={id} FOR UPDATE").SingleOrDefaultAsync();
            if(u is null||u.Role==AccountRole.Admin)return Results.NotFound();
            u.ApprovalStatus=r.Status;u.ReviewReason=Input.Text(r.Reason);
            db.AuditEntries.Add(SessionTokens.Audit(http.User.UserId(),u.Id,"ApplicationReviewed",$"{r.Status}: {u.ReviewReason}"));
            db.InteractionHistories.Add(new InteractionHistory{UserId=u.Id,Kind="ApplicationReviewed",Title="Kết quả xét duyệt",Body=u.ReviewReason});
            await db.SaveChangesAsync();await tx.CommitAsync();
            // Claims are reloaded each HTTP request; existing hubs must also lose stale permissions.
            connections.AbortUser(u.Id);return Results.Ok(SessionTokens.Profile(u));
        });
        admin.MapPost("/users/{id:guid}/status",async(Guid id,AccountStatusRequest r,HttpContext http,AppDbContext db,SessionConnections connections)=> {
            if(!Input.Safe(r.Reason))return Input.Invalid("Lý do không hợp lệ.");
            await using var tx=await db.Database.BeginTransactionAsync();
            var u=await db.Users.FromSqlInterpolated($"SELECT * FROM \"AspNetUsers\" WHERE \"Id\"={id} FOR UPDATE").SingleOrDefaultAsync();
            if(u is null)return Results.NotFound();
            if(u.Role==AccountRole.Admin)return Input.Invalid("Bản nền tảng chưa cho phép khóa tài khoản quản trị qua API này.");
            u.IsActive=r.IsActive;
            if(!r.IsActive)await db.AuthSessions.Where(x=>x.UserId==id).ExecuteUpdateAsync(x=>x.SetProperty(v=>v.RevokedAt,DateTimeOffset.UtcNow));
            db.AuditEntries.Add(SessionTokens.Audit(http.User.UserId(),u.Id,r.IsActive?"AccountUnlocked":"AccountLocked",Input.Text(r.Reason)));
            await db.SaveChangesAsync();await tx.CommitAsync();connections.AbortUser(id);
            return Results.Ok(new{user=SessionTokens.Profile(u),existingBusinessRecords="preserved",newActionsAllowed=r.IsActive});
        });
        admin.MapGet("/audit",async(int? limit,AppDbContext db)=> {
            if(!Input.Page(limit,out var size))return Input.Invalid("limit phải từ 1 đến 50.");
            return Results.Ok(new{items=await db.AuditEntries.AsNoTracking().OrderByDescending(x=>x.CreatedAt).ThenBy(x=>x.Id).Take(size).ToListAsync()});
        });
        admin.MapGet("/stats",async(AppDbContext db,AiRuntimeStatus ai)=>Results.Ok(new{
            users=await db.Users.CountAsync(),pendingApplications=await db.Users.CountAsync(x=>x.ApprovalStatus==ApprovalState.Pending),
            posts=await db.Posts.CountAsync(),messages=await db.Messages.CountAsync(),
            activeSessions=await db.AuthSessions.CountAsync(x=>x.RevokedAt==null&&x.AccessExpiresAt>DateTimeOffset.UtcNow),
            aiIntegrated=ai.IsReady,inventoryTradingImplemented=false}));
    }
}
