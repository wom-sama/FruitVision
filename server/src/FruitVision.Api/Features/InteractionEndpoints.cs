using FruitVision.Api.Auth;
using FruitVision.Api.Contracts;
using FruitVision.Api.Data;
using FruitVision.Api.Infrastructure;
using Microsoft.EntityFrameworkCore;
using Npgsql;

namespace FruitVision.Api.Features;

public static class InteractionEndpoints
{
    public static void MapInteractions(this WebApplication app)
    {
        app.MapPostWorkflow();
        app.MapCommunity();
        app.MapMarket();
        app.MapGet("/api/v1/catalog/products",async(AppDbContext db)=>Results.Ok(new{items=await db.Products.AsNoTracking().OrderBy(x=>x.Code).ToListAsync()}));
        app.MapGet("/api/v1/conversations", InboxEndpoints.List).RequireAuthorization("Approved");
        app.MapGet("/api/v1/conversations/{id:guid}/messages",async(Guid id,HttpContext http,int? limit,Guid? before,AppDbContext db)=> {
            if(!Input.Page(limit,out var size))return Input.Invalid("limit phải từ 1 đến 50.");
            var uid=http.User.UserId();
            if(!await db.Participants.AnyAsync(p=>p.ConversationId==id&&p.UserId==uid))return Results.NotFound();
            var q=db.Messages.AsNoTracking().Where(x=>x.ConversationId==id);
            if(before.HasValue){var a=await q.SingleOrDefaultAsync(x=>x.Id==before.Value);if(a is null)return Input.Invalid("Cursor không tồn tại trong hội thoại.");q=q.Where(x=>x.CreatedAt<a.CreatedAt||(x.CreatedAt==a.CreatedAt&&x.Id.CompareTo(a.Id)<0));}
            var rows=await q.Join(db.Users.AsNoTracking(),message=>message.SenderId,user=>user.Id,
                    (message,user)=>new{Message=message,SenderDisplayName=user.DisplayName,SenderRole=user.Role})
                .OrderByDescending(row=>row.Message.CreatedAt).ThenByDescending(row=>row.Message.Id).Take(size+1)
                .Select(row=>new{row.Message.Id,row.Message.ConversationId,row.Message.SenderId,row.Message.Text,row.Message.ClientMessageId,row.Message.CreatedAt,row.Message.NormalImageId,row.SenderDisplayName,row.SenderRole}).ToListAsync();
            var imageIds=rows.Where(row=>row.NormalImageId.HasValue).Select(row=>row.NormalImageId!.Value).ToArray();
            var images=await db.Set<NormalImage>().AsNoTracking().Where(image=>imageIds.Contains(image.Id)).ToDictionaryAsync(image=>image.Id);
            return Results.Ok(new{items=rows.Take(size).Select(row=>new{row.Id,row.ConversationId,row.SenderId,row.Text,row.ClientMessageId,row.CreatedAt,
                sender=new MessageSenderView(row.SenderId,row.SenderDisplayName,row.SenderRole.ToString()),
                image=row.NormalImageId.HasValue&&images.TryGetValue(row.NormalImageId.Value,out var image)?NormalMediaEndpoints.ImageView(image,$"/api/v1/conversations/{id}/images/{image.Id}"):null}),next=rows.Count>size?rows[size-1].Id:(Guid?)null});
        }).RequireAuthorization("Approved");
        app.MapPost("/api/v1/conversations/{id:guid}/messages",async(Guid id,SendMessageRequest r,HttpContext http,AppDbContext db)=> {
            if(!Input.Safe(r.Text,true))return Input.Invalid("Tin nhắn chứa ký tự điều khiển.");
            await using var transaction=await db.Database.BeginTransactionAsync();
            var uid=http.User.UserId();
            var access=await ProfileBlocks.LockNormalSendAsync(db,id,uid,http.RequestAborted);
            var conversation=access.Conversation;
            if(conversation is null)return Results.NotFound();
            if(access.Blocked)return Results.Problem(statusCode:403,title:"Tài khoản đã chặn liên hệ riêng.");
            var senderData=access.Sender;if(senderData is null)return Results.Forbid();
            var sender=new MessageSenderView(uid,senderData.DisplayName,senderData.Role.ToString());
            var text=Input.Text(r.Text);
            var old=await db.Messages.AsNoTracking().SingleOrDefaultAsync(x=>x.ConversationId==id&&x.SenderId==uid&&x.ClientMessageId==r.ClientMessageId);
            if(old is not null)return old.NormalImageId is null&&old.Text==text?Results.Ok(MessageView(old,sender)):Results.Conflict(new{message="Khóa tin nhắn đã được dùng với nội dung khác."});
            if(conversation.Kind=="Group"&&!conversation.IsOpen)return Results.Conflict(new{message="Nhóm đã đóng, không nhận tin nhắn mới."});
            var m=new Message{ConversationId=id,SenderId=uid,ClientMessageId=r.ClientMessageId,Text=text};
            db.Messages.Add(m);db.OutboxEvents.Add(new OutboxEvent{ConversationId=id,MessageId=m.Id});
            try{await db.SaveChangesAsync();await transaction.CommitAsync();}
            catch(DbUpdateException e) when(e.InnerException is PostgresException{SqlState:PostgresErrorCodes.UniqueViolation}) {
                await transaction.RollbackAsync();db.ChangeTracker.Clear();old=await db.Messages.AsNoTracking().SingleAsync(x=>x.ConversationId==id&&x.SenderId==uid&&x.ClientMessageId==r.ClientMessageId);
                return old.NormalImageId is null&&old.Text==text?Results.Ok(MessageView(old,sender)):Results.Conflict();
            }
            return Results.Created($"/api/v1/conversations/{id}/messages",MessageView(m,sender));
        }).RequireAuthorization("Approved").AddEndpointFilter<InputFilter>();
        app.MapGet("/api/v1/history",async(HttpContext http,int? limit,Guid? before,AppDbContext db)=> {
            if(!Input.Page(limit,out var size))return Input.Invalid("limit phải từ 1 đến 50.");
            var uid=http.User.UserId();var q=db.InteractionHistories.AsNoTracking().Where(x=>x.UserId==uid);
            if(before.HasValue){var a=await q.SingleOrDefaultAsync(x=>x.Id==before);if(a is null)return Input.Invalid("Cursor không hợp lệ.");q=q.Where(x=>x.CreatedAt<a.CreatedAt||(x.CreatedAt==a.CreatedAt&&x.Id.CompareTo(a.Id)<0));}
            var items=await q.OrderByDescending(x=>x.CreatedAt).ThenByDescending(x=>x.Id).Take(size+1).ToListAsync();
            return Results.Ok(new{items=items.Take(size),next=items.Count>size?items[size-1].Id:(Guid?)null});
        }).RequireAuthorization();
    }
    private static object MessageView(Message m,MessageSenderView sender)=>new{m.Id,m.ConversationId,m.SenderId,m.ClientMessageId,m.Text,m.CreatedAt,sender,image=(object?)null};
}
