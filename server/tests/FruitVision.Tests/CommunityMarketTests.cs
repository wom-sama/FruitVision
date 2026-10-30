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
public sealed class CommunityMarketTests(ApiFixture fixture)
{
    [Fact]
    public async Task Committed_group_creation_survives_cancelled_realtime_notification()
    {
        using var app = fixture.WithWebHostBuilder(builder => builder.ConfigureServices(services =>
            services.AddSingleton<IHubContext<FruitHub>>(new UnavailableHub())));
        using var owner = app.CreateClient();
        var uid = await NewAccount(owner);
        var group = await CreateGroup(owner, "Notify-" + Guid.NewGuid().ToString("N"));
        using var scope = fixture.Services.CreateScope(); var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
        var id = group.GetProperty("id").GetGuid();
        Assert.True(await db.Conversations.AnyAsync(c => c.Id == id && c.OwnerId == uid));
        Assert.True(await db.Participants.AnyAsync(p => p.ConversationId == id && p.UserId == uid));
    }
    [Fact]
    public async Task Community_requires_approval_and_creates_owner_membership_with_newest_cursor()
    {
        using var owner = fixture.CreateClient(); using var pending = fixture.CreateClient(); using var anonymous = fixture.CreateClient();
        var ownerId = await NewAccount(owner); await NewAccount(pending, approve: false);
        using var denied = await pending.GetAsync("/api/v1/community/groups"); Assert.Equal(HttpStatusCode.Forbidden, denied.StatusCode);
        using var unauthenticated = await anonymous.GetAsync("/api/v1/community/groups"); Assert.Equal(HttpStatusCode.Unauthorized, unauthenticated.StatusCode);
        var region = "Group-" + Guid.NewGuid().ToString("N");
        var first = await CreateGroup(owner, region); var second = await CreateGroup(owner, region);
        Assert.Equal(ownerId, second.GetProperty("ownerId").GetGuid()); Assert.True(second.GetProperty("isMember").GetBoolean());
        Assert.Equal("Owner", second.GetProperty("currentRole").GetString()); Assert.Equal(1, second.GetProperty("memberCount").GetInt32());
        var page = await Get(owner, $"/api/v1/community/groups?region={Uri.EscapeDataString(region)}&productCode=mango&limit=1");
        Assert.Equal(second.GetProperty("id").GetGuid(), page.GetProperty("items")[0].GetProperty("id").GetGuid());
        var next = await Get(owner, $"/api/v1/community/groups?region={Uri.EscapeDataString(region)}&limit=1&after={page.GetProperty("next").GetGuid()}");
        Assert.Equal(first.GetProperty("id").GetGuid(), next.GetProperty("items")[0].GetProperty("id").GetGuid());
        var lowerRegion = await Get(owner, $"/api/v1/community/groups?region={Uri.EscapeDataString(region.ToLowerInvariant())}&limit=50");
        Assert.Equal(2, lowerRegion.GetProperty("items").GetArrayLength());
        using var badCursor = await owner.GetAsync($"/api/v1/community/groups?after={Guid.NewGuid()}"); Assert.Equal(HttpStatusCode.BadRequest, badCursor.StatusCode);
    }

    [Fact]
    public async Task Join_is_atomic_idempotent_and_never_admits_an_arbitrary_user_or_direct_thread()
    {
        using var owner = fixture.CreateClient(); using var member = fixture.CreateClient();
        var ownerId = await NewAccount(owner); var memberId = await NewAccount(member);
        var id = (await CreateGroup(owner, "Join-" + Guid.NewGuid().ToString("N"))).GetProperty("id").GetGuid();
        var responses = await Task.WhenAll(Enumerable.Range(0, 6).Select(_ => member.PostAsJsonAsync($"/api/v1/community/groups/{id}/join", new { })));
        try { Assert.Single(responses, response => response.StatusCode == HttpStatusCode.Created); Assert.All(responses, response => Assert.True(response.StatusCode is HttpStatusCode.OK or HttpStatusCode.Created)); }
        finally { foreach (var response in responses) response.Dispose(); }
        using var injection = await member.PostAsJsonAsync($"/api/v1/community/groups/{id}/join", new { userId = Guid.NewGuid() }); Assert.Equal(HttpStatusCode.BadRequest, injection.StatusCode);
        var directId = Guid.NewGuid();
        using (var scope = fixture.Services.CreateScope())
        {
            var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
            db.Conversations.Add(new Conversation { Id = directId, Title = "Private direct", Kind = "Direct" });
            db.Participants.Add(new Participant { ConversationId = directId, UserId = ownerId }); await db.SaveChangesAsync();
            Assert.Equal(1, await db.Participants.CountAsync(p => p.ConversationId == id && p.UserId == memberId));
        }
        using var direct = await member.PostAsJsonAsync($"/api/v1/community/groups/{directId}/join", new { }); Assert.Equal(HttpStatusCode.NotFound, direct.StatusCode);
        using var directRead = await member.GetAsync($"/api/v1/community/groups/{directId}"); Assert.Equal(HttpStatusCode.NotFound, directRead.StatusCode);
    }

    [Fact]
    public async Task Leave_and_close_enforce_current_membership_and_owner_authority()
    {
        using var owner = fixture.CreateClient(); using var member = fixture.CreateClient(); using var outsider = fixture.CreateClient();
        await NewAccount(owner); await NewAccount(member); await NewAccount(outsider);
        var id = (await CreateGroup(owner, "Leave-" + Guid.NewGuid().ToString("N"))).GetProperty("id").GetGuid();
        using var joined = await member.PostAsJsonAsync($"/api/v1/community/groups/{id}/join", new { }); Assert.Equal(HttpStatusCode.Created, joined.StatusCode);
        using var ownerLeave = await owner.PostAsJsonAsync($"/api/v1/community/groups/{id}/leave", new { }); Assert.Equal(HttpStatusCode.Conflict, ownerLeave.StatusCode);
        using var deniedClose = await outsider.PostAsJsonAsync($"/api/v1/community/groups/{id}/close", new { }); Assert.Equal(HttpStatusCode.Forbidden, deniedClose.StatusCode);
        using var closed = await owner.PostAsJsonAsync($"/api/v1/community/groups/{id}/close", new { }); Assert.Equal(HttpStatusCode.OK, closed.StatusCode);
        using var cannotJoin = await outsider.PostAsJsonAsync($"/api/v1/community/groups/{id}/join", new { }); Assert.Equal(HttpStatusCode.Conflict, cannotJoin.StatusCode);
        Assert.False((await Get(member, $"/api/v1/community/groups/{id}")).GetProperty("isOpen").GetBoolean());
        using var hidden = await outsider.GetAsync($"/api/v1/community/groups/{id}"); Assert.Equal(HttpStatusCode.NotFound, hidden.StatusCode);
        using var cannotSend = await member.PostAsJsonAsync($"/api/v1/conversations/{id}/messages", new { clientMessageId = Guid.NewGuid().ToString("N"), text = "Closed group" }); Assert.Equal(HttpStatusCode.Conflict, cannotSend.StatusCode);
        using var leave = await member.PostAsJsonAsync($"/api/v1/community/groups/{id}/leave", new { }); Assert.Equal(HttpStatusCode.OK, leave.StatusCode);
        using var leaveAgain = await member.PostAsJsonAsync($"/api/v1/community/groups/{id}/leave", new { }); Assert.Equal(HttpStatusCode.OK, leaveAgain.StatusCode);
        using var messages = await member.GetAsync($"/api/v1/conversations/{id}/messages"); Assert.Equal(HttpStatusCode.NotFound, messages.StatusCode);
    }

    [Fact]
    public async Task Concurrent_joins_respect_fifty_member_cap_and_creates_respect_ten_open_groups()
    {
        using var owner = fixture.CreateClient(); using var first = fixture.CreateClient(); using var second = fixture.CreateClient();
        var ownerId = await NewAccount(owner); await NewAccount(first); await NewAccount(second);
        var region = "Cap-" + Guid.NewGuid().ToString("N");
        var id = (await CreateGroup(owner, region)).GetProperty("id").GetGuid();
        using (var scope = fixture.Services.CreateScope())
        {
            var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
            for (var index = 0; index < 48; index++)
            {
                var user = User(region); db.Users.Add(user); db.Participants.Add(new Participant { ConversationId = id, UserId = user.Id });
            }
            for (var index = 0; index < 8; index++)
            {
                var group = new Conversation { Kind = "Group", OwnerId = ownerId, Title = "Cap seeded group", Region = region, IsOpen = true };
                db.Conversations.Add(group); db.Participants.Add(new Participant { ConversationId = group.Id, UserId = ownerId });
            }
            await db.SaveChangesAsync();
        }
        var joins = await Task.WhenAll(first.PostAsJsonAsync($"/api/v1/community/groups/{id}/join", new { }), second.PostAsJsonAsync($"/api/v1/community/groups/{id}/join", new { }));
        try { Assert.Single(joins, response => response.StatusCode == HttpStatusCode.Created); Assert.Single(joins, response => response.StatusCode == HttpStatusCode.Conflict); }
        finally { foreach (var response in joins) response.Dispose(); }
        var creates = await Task.WhenAll(Enumerable.Range(0, 2).Select(_ => owner.PostAsJsonAsync("/api/v1/community/groups", new { title = "Concurrent cap group", region, productCode = "mango" })));
        try { Assert.Single(creates, response => response.StatusCode == HttpStatusCode.Created); Assert.Single(creates, response => response.StatusCode == HttpStatusCode.Conflict); }
        finally { foreach (var response in creates) response.Dispose(); }
        Assert.Equal(50, (await Get(owner, $"/api/v1/community/groups/{id}")).GetProperty("memberCount").GetInt32());
    }

    [Fact]
    public async Task Public_market_aggregates_only_published_active_approved_posts_with_real_price_median()
    {
        using var reader = fixture.CreateClient(); var region = "Market-" + Guid.NewGuid().ToString("N");
        using (var scope = fixture.Services.CreateScope())
        {
            var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
            var supply = User(region); var demand = User(region); var pending = User(region); pending.ApprovalStatus = ApprovalState.Pending;
            var inactive = User(region); inactive.IsActive = false; db.Users.AddRange(supply, demand, pending, inactive);
            db.Posts.AddRange(Post(supply, "Supply", 10, 10000, 20000), Post(supply, "Supply", 20, 30000, 50000),
                Post(demand, "Demand", 40, 9000000, 9900000), Post(pending, "Supply", 900, 1, 2), Post(inactive, "Supply", 900, 1, 2));
            var privatePost = Post(supply, "Supply", 900, 1, 2); privatePost.Status = "AwaitingReview"; db.Posts.Add(privatePost);
            var otherRegion = Post(supply, "Supply", 900, 1, 2); otherRegion.Region = region + "Other"; db.Posts.Add(otherRegion);
            var otherProduct = Post(supply, "Supply", 900, 1, 2); otherProduct.ProductCode = "orange"; db.Posts.Add(otherProduct);
            await db.SaveChangesAsync();
        }
        var summary = await Get(reader, $"/api/v1/market/summary?region={Uri.EscapeDataString(region.ToLowerInvariant())}&productCode=mango");
        Assert.Equal("published-user-asking-prices", summary.GetProperty("source").GetString()); Assert.False(summary.GetProperty("isForecast").GetBoolean());
        var item = Assert.Single(summary.GetProperty("items").EnumerateArray());
        Assert.Equal(30m, item.GetProperty("supplyEstimatedKg").GetDecimal()); Assert.Equal(40m, item.GetProperty("demandEstimatedKg").GetDecimal());
        Assert.Equal(2, item.GetProperty("supplyPostCount").GetInt32()); Assert.Equal(1, item.GetProperty("demandPostCount").GetInt32());
        Assert.Equal(2, item.GetProperty("contributorCount").GetInt32()); Assert.Equal(27500m, item.GetProperty("referencePriceVndPerKg").GetDecimal());
        Assert.Equal(10000m, item.GetProperty("priceMinVndPerKg").GetDecimal()); Assert.Equal(50000m, item.GetProperty("priceMaxVndPerKg").GetDecimal());
        Assert.Equal(2, item.GetProperty("priceSampleCount").GetInt32()); Assert.NotEmpty(summary.GetProperty("limitations").EnumerateArray());
    }

    [Fact]
    public async Task Market_keeps_missing_prices_null_and_validates_filters()
    {
        using var reader = fixture.CreateClient(); var region = "NoPrice-" + Guid.NewGuid().ToString("N");
        using (var scope = fixture.Services.CreateScope())
        {
            var db = scope.ServiceProvider.GetRequiredService<AppDbContext>(); var user = User(region); db.Users.Add(user);
            db.Posts.Add(Post(user, "Supply", 12, null, null)); await db.SaveChangesAsync();
        }
        var item = Assert.Single((await Get(reader, $"/api/v1/market/summary?region={Uri.EscapeDataString(region)}")).GetProperty("items").EnumerateArray());
        Assert.Equal(region, item.GetProperty("region").GetString()); Assert.Equal(0, item.GetProperty("priceSampleCount").GetInt32());
        Assert.Equal(JsonValueKind.Null, item.GetProperty("referencePriceVndPerKg").ValueKind);
        Assert.Equal(JsonValueKind.Null, item.GetProperty("priceMinVndPerKg").ValueKind); Assert.Equal(JsonValueKind.Null, item.GetProperty("priceMaxVndPerKg").ValueKind);
        using var badRegion = await reader.GetAsync("/api/v1/market/summary?region=x"); Assert.Equal(HttpStatusCode.BadRequest, badRegion.StatusCode);
        using var badProduct = await reader.GetAsync("/api/v1/market/summary?productCode=not-a-product"); Assert.Equal(HttpStatusCode.BadRequest, badProduct.StatusCode);
    }

    private static AppUser User(string region) => new() { Id = Guid.NewGuid(), DisplayName = "Market contributor", Region = region, Role = AccountRole.Consumer, ApprovalStatus = ApprovalState.Approved, IsActive = true, UserName = Guid.NewGuid().ToString("N") };
    private static Post Post(AppUser user, string purpose, decimal quantity, decimal? min, decimal? max) => new() { AuthorId = user.Id, Author = user, Title = "Published market estimate", Body = "An estimate without a stock or delivery commitment.", ProductCode = "mango", Status = "Published", Purpose = purpose, Region = "", EstimatedQuantityKg = quantity, PriceMinVndPerKg = min, PriceMaxVndPerKg = max };
    private async Task<Guid> NewAccount(HttpClient client, bool approve = true)
    {
        var account = await TestAccounts.CreateAsync(fixture.Services,fixture.Password,"Consumer",approve,"Community test");
        await Login(client, account.Email); return account.Id;
    }
    private async Task Login(HttpClient client, string email)
    {
        using var response = await client.PostAsJsonAsync("/api/v1/auth/login", new { email, password = fixture.Password }); Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", (await response.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("accessToken").GetString());
    }
    private static async Task<JsonElement> CreateGroup(HttpClient client, string region)
    { using var response = await client.PostAsJsonAsync("/api/v1/community/groups", new { title = "Local fruit discussion", region, productCode = "mango" }); Assert.Equal(HttpStatusCode.Created, response.StatusCode); return await response.Content.ReadFromJsonAsync<JsonElement>(); }
    private static async Task<JsonElement> Get(HttpClient client, string path)
    { using var response = await client.GetAsync(path); Assert.Equal(HttpStatusCode.OK, response.StatusCode); return await response.Content.ReadFromJsonAsync<JsonElement>(); }

    private sealed class UnavailableHub : IHubContext<FruitHub>
    {
        public IHubClients Clients { get; } = new UnavailableClients();
        public IGroupManager Groups { get; } = new EmptyGroups();
    }
    private sealed class UnavailableClients : IHubClients
    {
        private static readonly IClientProxy Proxy = new UnavailableProxy();
        public IClientProxy All => Proxy;
        public IClientProxy AllExcept(IReadOnlyList<string> excludedConnectionIds) => Proxy;
        public IClientProxy Client(string connectionId) => Proxy;
        public IClientProxy Clients(IReadOnlyList<string> connectionIds) => Proxy;
        public IClientProxy Group(string groupName) => Proxy;
        public IClientProxy GroupExcept(string groupName, IReadOnlyList<string> excludedConnectionIds) => Proxy;
        public IClientProxy Groups(IReadOnlyList<string> groupNames) => Proxy;
        public IClientProxy User(string userId) => Proxy;
        public IClientProxy Users(IReadOnlyList<string> userIds) => Proxy;
    }
    private sealed class UnavailableProxy : IClientProxy
    {
        public Task SendCoreAsync(string method, object?[] args, CancellationToken cancellationToken = default) =>
            throw new OperationCanceledException("Simulated notification cancellation after database commit.");
    }
    private sealed class EmptyGroups : IGroupManager
    {
        public Task AddToGroupAsync(string connectionId, string groupName, CancellationToken cancellationToken = default) => Task.CompletedTask;
        public Task RemoveFromGroupAsync(string connectionId, string groupName, CancellationToken cancellationToken = default) => Task.CompletedTask;
    }
}
