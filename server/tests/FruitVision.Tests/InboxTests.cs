using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text.Json;
using FruitVision.Api.Data;
using FruitVision.Api.Realtime;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.SignalR;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
using Xunit;

namespace FruitVision.Tests;

[Collection("Api")]
public sealed class InboxTests(ApiFixture fixture)
{
    [Fact]
    public async Task Read_ack_notifies_only_own_user_with_fresh_metadata_event_id_after_commit()
    {
        var hub = new ReadNotifications();
        using var app = fixture.WithWebHostBuilder(builder => builder.ConfigureServices(services => services.AddSingleton<IHubContext<FruitHub>>(hub)));
        using var owner = app.CreateClient(); var user = await Login(owner); var peer = await Account(); var id = await Direct(user.Id, peer.Id);
        var message = new Message { ConversationId = id, SenderId = peer.Id, ClientMessageId = Guid.NewGuid().ToString("N"), Text = "Private text never belongs in a badge event" };
        using (var scope = fixture.Services.CreateScope()) { var db = scope.ServiceProvider.GetRequiredService<AppDbContext>(); db.Add(message); await db.SaveChangesAsync(); }
        hub.VerifyCommitted = async () => { using var scope = fixture.Services.CreateScope(); var saved = await scope.ServiceProvider.GetRequiredService<AppDbContext>().Set<ConversationReadState>().AsNoTracking().SingleAsync(s => s.ConversationId == id && s.UserId == user.Id); Assert.Equal(message.Id, saved.LastNormalMessageId); };
        for (var i = 0; i < 2; i++) { using var response = await owner.PostAsJsonAsync($"/api/v1/conversations/{id}/read", new { lastMessageId = message.Id }); Assert.Equal(HttpStatusCode.OK, response.StatusCode); }
        Assert.Equal(2, hub.Events.Count); Assert.All(hub.GroupsUsed, group => Assert.Equal($"user:{user.Id}", group));
        Assert.All(hub.Events, payload => { Assert.Equal(id, payload.GetProperty("id").GetGuid()); Assert.Equal(new[] { "eventId", "id" }, payload.EnumerateObject().Select(p => p.Name).Order().ToArray()); });
        Assert.NotEqual(hub.Events[0].GetProperty("eventId").GetGuid(), hub.Events[1].GetProperty("eventId").GetGuid());
        using var savedScope = fixture.Services.CreateScope(); Assert.Equal(message.Id, (await savedScope.ServiceProvider.GetRequiredService<AppDbContext>().Set<ConversationReadState>().SingleAsync(s => s.ConversationId == id && s.UserId == user.Id)).LastNormalMessageId);
    }
    [Fact]
    public async Task Old_active_direct_is_first_with_peer_preview_and_incoming_only_unread_summary()
    {
        using var owner = fixture.CreateClient(); var user = await Login(owner); var peer = await Account("Trader");
        var id = await Direct(user.Id, peer.Id); var dormant = await Direct(user.Id, peer.Id);
        using (var scope = fixture.Services.CreateScope())
        {
            var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
            (await db.Conversations.SingleAsync(c => c.Id == id)).CreatedAt = DateTimeOffset.UtcNow.AddDays(-90);
            (await db.Conversations.SingleAsync(c => c.Id == dormant)).CreatedAt = DateTimeOffset.UtcNow.AddDays(-95);
            db.Messages.Add(new Message { ConversationId = dormant, SenderId = peer.Id, ClientMessageId = Guid.NewGuid().ToString("N"), Text = "Older unread outside first page", CreatedAt = DateTimeOffset.UtcNow.AddDays(-94) });
            for (var i = 0; i < 25; i++) { var empty = new Conversation { Title = "New empty thread", CreatedAt = DateTimeOffset.UtcNow.AddDays(-2) }; db.Add(empty); db.Participants.Add(new Participant { ConversationId = empty.Id, UserId = user.Id }); }
            db.Messages.Add(new Message { ConversationId = id, SenderId = peer.Id, ClientMessageId = Guid.NewGuid().ToString("N"), Text = "Incoming observation", CreatedAt = DateTimeOffset.UtcNow.AddMinutes(-1) });
            db.Messages.Add(new Message { ConversationId = id, SenderId = user.Id, ClientMessageId = Guid.NewGuid().ToString("N"), Text = "My latest reply" }); await db.SaveChangesAsync();
        }
        var inbox = await Get(owner, "/api/v1/conversations?limit=20"); var first = inbox.GetProperty("items")[0];
        Assert.Equal(id, first.GetProperty("id").GetGuid()); Assert.Equal(peer.Id, first.GetProperty("peer").GetProperty("id").GetGuid()); Assert.Equal("Trader", first.GetProperty("peer").GetProperty("role").GetString());
        Assert.Equal("My latest reply", first.GetProperty("lastMessage").GetProperty("text").GetString()); Assert.Equal("text", first.GetProperty("lastMessage").GetProperty("kind").GetString()); Assert.Equal(1, first.GetProperty("unreadCount").GetInt32());
        Assert.Equal(2, inbox.GetProperty("summary").GetProperty("unreadTotal").GetInt64()); Assert.Equal(2, inbox.GetProperty("summary").GetProperty("unreadConversations").GetInt32());
        Assert.False(first.GetProperty("lastMessageEncrypted").GetBoolean()); Assert.DoesNotContain("email", first.GetProperty("peer").GetRawText(), StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public async Task Displayed_normal_cursor_is_monotonic_durable_and_does_not_clear_newer_or_foreign_messages()
    {
        using var owner = fixture.CreateClient(); var user = await Login(owner); var peer = await Account(); var id = await Direct(user.Id, peer.Id);
        var old = new Message { ConversationId = id, SenderId = peer.Id, ClientMessageId = "old-" + Guid.NewGuid().ToString("N"), Text = "Older incoming", CreatedAt = DateTimeOffset.UtcNow.AddSeconds(-2) };
        var next = new Message { ConversationId = id, SenderId = peer.Id, ClientMessageId = "next-" + Guid.NewGuid().ToString("N"), Text = "Newer incoming", CreatedAt = DateTimeOffset.UtcNow.AddSeconds(-1) };
        using (var scope = fixture.Services.CreateScope()) { var db = scope.ServiceProvider.GetRequiredService<AppDbContext>(); db.AddRange(old, next); await db.SaveChangesAsync(); }
        using var first = await owner.PostAsJsonAsync($"/api/v1/conversations/{id}/read", new { lastMessageId = old.Id }); Assert.Equal(HttpStatusCode.OK, first.StatusCode); Assert.Equal(1, (await first.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("unreadCount").GetInt32());
        var concurrent = await Task.WhenAll(owner.PostAsJsonAsync($"/api/v1/conversations/{id}/read", new { lastMessageId = next.Id }), owner.PostAsJsonAsync($"/api/v1/conversations/{id}/read", new { lastMessageId = old.Id }));
        try { Assert.All(concurrent, r => Assert.Equal(HttpStatusCode.OK, r.StatusCode)); } finally { foreach (var r in concurrent) r.Dispose(); }
        Assert.Equal(0, (await Get(owner, "/api/v1/conversations/summary")).GetProperty("unreadTotal").GetInt64());
        var foreign = await Direct(user.Id, peer.Id); using var mismatch = await owner.PostAsJsonAsync($"/api/v1/conversations/{foreign}/read", new { lastMessageId = next.Id }); Assert.Equal(HttpStatusCode.BadRequest, mismatch.StatusCode);
        using var scope2 = fixture.Services.CreateScope(); var saved = await scope2.ServiceProvider.GetRequiredService<AppDbContext>().Set<ConversationReadState>().SingleAsync(s => s.ConversationId == id && s.UserId == user.Id); Assert.Equal(next.Id, saved.LastNormalMessageId);
    }

    [Fact]
    public async Task Inbox_and_read_ack_are_membership_scoped_and_reject_empty_or_injected_cursors()
    {
        using var owner = fixture.CreateClient(); using var outsider = fixture.CreateClient(); using var pending = fixture.CreateClient(); using var anonymous = fixture.CreateClient();
        var user = await Login(owner); await Login(outsider); await Login(pending, approve: false); var peer = await Account(); var id = await Direct(user.Id, peer.Id);
        using var denied = await outsider.PostAsJsonAsync($"/api/v1/conversations/{id}/read", new { lastMessageId = Guid.NewGuid() }); Assert.Equal(HttpStatusCode.NotFound, denied.StatusCode);
        using var empty = await owner.PostAsJsonAsync($"/api/v1/conversations/{id}/read", new { }); Assert.Equal(HttpStatusCode.BadRequest, empty.StatusCode);
        using var injected = await owner.PostAsJsonAsync($"/api/v1/conversations/{id}/read", new { lastMessageId = Guid.NewGuid(), userId = peer.Id }); Assert.Equal(HttpStatusCode.BadRequest, injected.StatusCode);
        using var unauthenticated = await anonymous.GetAsync("/api/v1/conversations"); Assert.Equal(HttpStatusCode.Unauthorized, unauthenticated.StatusCode);
        using var unapproved = await pending.GetAsync("/api/v1/conversations"); Assert.Equal(HttpStatusCode.Forbidden, unapproved.StatusCode);
        Assert.DoesNotContain((await Get(outsider, "/api/v1/conversations")).GetProperty("items").EnumerateArray(), c => c.GetProperty("id").GetGuid() == id);
    }

    [Fact]
    public async Task Eligible_secret_activity_is_generic_unread_and_lost_seller_eligibility_hides_it()
    {
        using var owner = fixture.CreateClient(); var user = await Login(owner, "Producer"); var peer = await Account("Trader"); var directId = await Direct(user.Id, peer.Id); Guid secretId;
        using (var scope = fixture.Services.CreateScope())
        {
            var db = scope.ServiceProvider.GetRequiredService<AppDbContext>(); var device = new SecretDevice { DeviceId = Guid.NewGuid(), UserId = peer.Id, Version = 1, Label = "Isolated metadata fixture", EncryptionPublicKey = Convert.ToBase64String(new byte[32]), SigningPublicKey = Convert.ToBase64String(new byte[32]) };
            var secret = new SecretConversation { DirectConversationId = directId, FirstUserId = user.Id, SecondUserId = peer.Id, NextSequence = 1 }; secretId = secret.Id;
            db.AddRange(device, secret, new SecretMessage { ConversationId = secret.Id, SenderUserId = peer.Id, SenderDeviceId = device.DeviceId, SenderKeyVersion = 1, Sequence = 1, ClientMessageId = Guid.NewGuid(), RequestHash = new string('a', 64) }); await db.SaveChangesAsync();
        }
        var row = Assert.Single((await Get(owner, "/api/v1/conversations")).GetProperty("items").EnumerateArray()); Assert.Equal(secretId, row.GetProperty("secretConversationId").GetGuid()); Assert.Equal(1, row.GetProperty("unreadCount").GetInt32()); Assert.True(row.GetProperty("lastMessageEncrypted").GetBoolean()); Assert.Equal("Tin nhắn mã hóa", row.GetProperty("lastMessage").GetProperty("text").GetString()); Assert.DoesNotContain("ciphertext", row.GetRawText(), StringComparison.OrdinalIgnoreCase);
        using var invalid = await owner.PostAsJsonAsync($"/api/v1/conversations/{directId}/read", new { lastSecretSequence = 2 }); Assert.Equal(HttpStatusCode.BadRequest, invalid.StatusCode);
        using var read = await owner.PostAsJsonAsync($"/api/v1/conversations/{directId}/read", new { lastSecretSequence = 1 }); Assert.Equal(HttpStatusCode.OK, read.StatusCode);
        Assert.Equal(0, (await Get(owner, "/api/v1/conversations/summary")).GetProperty("unreadTotal").GetInt64());
        using (var scope = fixture.Services.CreateScope()) { var db = scope.ServiceProvider.GetRequiredService<AppDbContext>(); (await db.Users.SingleAsync(u => u.Id == peer.Id)).Role = AccountRole.Consumer; await db.SaveChangesAsync(); }
        row = Assert.Single((await Get(owner, "/api/v1/conversations")).GetProperty("items").EnumerateArray()); Assert.Equal(JsonValueKind.Null, row.GetProperty("secretConversationId").ValueKind); Assert.Equal(JsonValueKind.Null, row.GetProperty("lastMessage").ValueKind);
    }

    private Task<TestAccount> Account(string role = "Consumer", bool approve = true) => TestAccounts.CreateAsync(fixture.Services, fixture.Password, role, approve, "Inbox fixture");
    private async Task<TestAccount> Login(HttpClient client, string role = "Consumer", bool approve = true)
    { var account = await Account(role, approve); using var response = await client.PostAsJsonAsync("/api/v1/auth/login", new { email = account.Email, password = fixture.Password }); Assert.Equal(HttpStatusCode.OK, response.StatusCode); client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", (await response.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("accessToken").GetString()); return account; }
    private async Task<Guid> Direct(Guid first, Guid second)
    { using var scope = fixture.Services.CreateScope(); var db = scope.ServiceProvider.GetRequiredService<AppDbContext>(); var conversation = new Conversation { Title = "Inbox direct", Kind = "Direct" }; db.Add(conversation); db.Participants.AddRange(new Participant { ConversationId = conversation.Id, UserId = first }, new Participant { ConversationId = conversation.Id, UserId = second }); await db.SaveChangesAsync(); return conversation.Id; }
    private static async Task<JsonElement> Get(HttpClient client, string route)
    { using var response = await client.GetAsync(route); Assert.Equal(HttpStatusCode.OK, response.StatusCode); return await response.Content.ReadFromJsonAsync<JsonElement>(); }

    private sealed class ReadNotifications : IHubContext<FruitHub>, IHubClients, IClientProxy
    {
        public List<JsonElement> Events { get; } = [];
        public List<string> GroupsUsed { get; } = [];
        public Func<Task>? VerifyCommitted { get; set; }
        IHubClients IHubContext<FruitHub>.Clients => this;
        IGroupManager IHubContext<FruitHub>.Groups => throw new NotSupportedException();
        public IClientProxy Group(string group) => new NotificationProxy(this, new[] { group });
        public async Task SendCoreAsync(string method, object?[] args, CancellationToken ct = default)
        { if (method == "InboxChanged") { if (VerifyCommitted is not null) await VerifyCommitted(); Events.Add(JsonSerializer.SerializeToElement(args[0], new JsonSerializerOptions(JsonSerializerDefaults.Web))); } }
        public IClientProxy All => Group("all");
        public IClientProxy AllExcept(IReadOnlyList<string> ids) => All;
        public IClientProxy Client(string id) => Group("client:" + id);
        public IClientProxy Clients(IReadOnlyList<string> ids) => All;
        public IClientProxy GroupExcept(string group, IReadOnlyList<string> ids) => Group(group);
        public IClientProxy Groups(IReadOnlyList<string> groups) => new NotificationProxy(this, groups);
        public IClientProxy User(string id) => Group("identity:" + id);
        public IClientProxy Users(IReadOnlyList<string> ids) => All;
        private sealed class NotificationProxy(ReadNotifications owner, IReadOnlyList<string> groups) : IClientProxy
        {
            public async Task SendCoreAsync(string method, object?[] args, CancellationToken ct = default)
            {
                if (method != "InboxChanged") return; // Other test hosts may drain unrelated outbox messages.
                owner.GroupsUsed.AddRange(groups);
                await owner.SendCoreAsync(method, args, ct);
            }
        }
    }
}
