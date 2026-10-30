using System.Collections.Concurrent;
using FruitVision.Api.Auth;
using FruitVision.Api.Data;
using FruitVision.Api.Contracts;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.SignalR;
using Microsoft.EntityFrameworkCore;

namespace FruitVision.Api.Realtime;

public sealed class SessionConnections : IDisposable
{
    private sealed record Entry(Guid User,Guid Session,HubCallerContext Context,Timer Expiry);
    private readonly ConcurrentDictionary<string,Entry> _connections=new();
    public void Add(HubCallerContext context)
    {
        var due=DateTimeOffset.FromUnixTimeSeconds(long.Parse(context.User!.FindFirst("access_exp")!.Value))-DateTimeOffset.UtcNow;
        if(due<=TimeSpan.Zero){context.Abort();return;}
        var timer=new Timer(_=>context.Abort(),null,due,Timeout.InfiniteTimeSpan);
        _connections[context.ConnectionId]=new(context.User.UserId(),context.User.SessionId(),context,timer);
    }
    public void Remove(string id){if(_connections.TryRemove(id,out var c))c.Expiry.Dispose();}
    public void AbortSession(Guid id){foreach(var c in _connections.Values.Where(x=>x.Session==id))c.Context.Abort();}
    public void AbortUser(Guid id){foreach(var c in _connections.Values.Where(x=>x.User==id))c.Context.Abort();}
    public void Dispose(){foreach(var c in _connections.Values)c.Expiry.Dispose();_connections.Clear();}
}

[Authorize(Policy="Approved")]
public class FruitHub(AppDbContext db,SessionConnections connections) : Hub
{
    public override async Task OnConnectedAsync()
    {
        connections.Add(Context);
        await Groups.AddToGroupAsync(Context.ConnectionId,$"user:{Context.User!.UserId()}");
        await Groups.AddToGroupAsync(Context.ConnectionId,"approved");
        if(Context.User!.IsInRole("Admin"))await Groups.AddToGroupAsync(Context.ConnectionId,"role:Admin");
        await base.OnConnectedAsync();
    }
    public async Task JoinConversation(Guid id)
    {
        var uid=Context.User!.UserId();
        var sid=Context.User!.SessionId();
        if(!await db.AuthSessions.AnyAsync(x=>x.Id==sid&&x.RevokedAt==null&&x.AccessExpiresAt>DateTimeOffset.UtcNow&&x.User.IsActive&&x.User.ApprovalStatus==ApprovalState.Approved))
            throw new HubException("Phiên đã hết hiệu lực.");
        if(!await db.Participants.AnyAsync(x=>x.ConversationId==id&&x.UserId==uid))throw new HubException("Không có quyền vào hội thoại.");
        await Groups.AddToGroupAsync(Context.ConnectionId,$"conversation:{id}");
    }
    public override async Task OnDisconnectedAsync(Exception? exception){connections.Remove(Context.ConnectionId);await base.OnDisconnectedAsync(exception);}
}

public class OutboxDispatcher(IServiceScopeFactory scopes,IHubContext<FruitHub> hub,ILogger<OutboxDispatcher> log) : BackgroundService
{
    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        using var timer=new PeriodicTimer(TimeSpan.FromSeconds(2));
        while(await timer.WaitForNextTickAsync(stoppingToken))
        {
            try {
                using var scope=scopes.CreateScope();var db=scope.ServiceProvider.GetRequiredService<AppDbContext>();
                var rows=await db.OutboxEvents.Where(x=>x.SentAt==null).OrderBy(x=>x.CreatedAt).Take(50).ToListAsync(stoppingToken);
                foreach(var item in rows) {
                    var m=await db.Messages.AsNoTracking().Where(message=>message.Id==item.MessageId)
                        .Join(db.Users.AsNoTracking(),message=>message.SenderId,user=>user.Id,
                            (message,user)=>new{message.Id,message.ConversationId,message.SenderId,message.Text,message.CreatedAt,
                                SenderDisplayName=user.DisplayName,SenderRole=user.Role}).SingleAsync(stoppingToken);
                    // Refresh membership at dispatch; a departed group member must not receive future messages.
                    var recipients=await db.Participants.Where(p=>p.ConversationId==item.ConversationId).Select(p=>p.UserId).ToListAsync(stoppingToken);
                    await hub.Clients.Groups(recipients.Select(uid=>$"user:{uid}").ToArray()).SendAsync("MessageCreated",
                        new{schemaVersion=1,eventId=item.Id,m.Id,m.ConversationId,m.SenderId,m.Text,m.CreatedAt,
                            sender=new MessageSenderView(m.SenderId,m.SenderDisplayName,m.SenderRole.ToString())},stoppingToken);
                    item.SentAt=DateTimeOffset.UtcNow;
                }
                await db.SaveChangesAsync(stoppingToken);
            } catch(OperationCanceledException) when(stoppingToken.IsCancellationRequested){break;}
              catch(Exception ex){log.LogError(ex,"Outbox delivery failed; pending events remain durable.");}
        }
    }
}
