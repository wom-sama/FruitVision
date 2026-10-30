using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Net.WebSockets;
using System.Text;
using System.Text.Json;
using FruitVision.Api.Data;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
using Xunit;

namespace FruitVision.Tests;

[Collection("Api")]
public sealed class PostWorkflowTests(ApiFixture fixture)
{
    private readonly Dictionary<HttpClient,Guid?> branches = [];
    [Fact]
    public async Task Admin_can_list_submissions_and_publish_pause_republish_with_private_reasons()
    {
        using var author = fixture.CreateClient();
        using var admin = fixture.CreateClient();
        using var reader = fixture.CreateClient();
        await NewAccount(author, "Producer"); await Login(admin, "admin@fruitvision.test");
        var post = await Submit(author); var id = post.GetProperty("id").GetGuid();
        using var hidden = await reader.GetAsync($"/api/v1/posts/{id}"); Assert.Equal(HttpStatusCode.NotFound, hidden.StatusCode);
        var list = await Get(admin, "/api/v1/admin/posts?status=AwaitingReview&limit=50");
        Assert.Contains(list.GetProperty("items").EnumerateArray(), row => row.GetProperty("id").GetGuid() == id);
        var own = await Get(author, "/api/v1/me/posts");
        var submitted = own.GetProperty("items").EnumerateArray().Single(row => row.GetProperty("id").GetGuid() == id);
        Assert.Equal(1, submitted.GetProperty("revision").GetInt32()); Assert.True(submitted.TryGetProperty("body", out _));
        Assert.True(submitted.TryGetProperty("author", out _)); Assert.True(submitted.TryGetProperty("reviewReason", out _));
        var published = await Review(admin, id, "Published", 1);
        Assert.Equal(2, published.GetProperty("revision").GetInt32());
        var visible = await Get(reader, $"/api/v1/posts/{id}");
        Assert.False(visible.TryGetProperty("reviewReason", out _));
        Assert.False(visible.GetProperty("canOrder").GetBoolean()); Assert.Equal(JsonValueKind.Null, visible.GetProperty("actualStockKg").ValueKind);
        Assert.Equal("Reviewed for integration test", (await Get(author, $"/api/v1/posts/{id}")).GetProperty("reviewReason").GetString());
        await Review(admin, id, "Paused", 2);
        using var paused = await reader.GetAsync($"/api/v1/posts/{id}"); Assert.Equal(HttpStatusCode.NotFound, paused.StatusCode);
        await Review(admin, id, "Published", 3);
        Assert.Equal("Published", (await Get(reader, $"/api/v1/posts/{id}")).GetProperty("status").GetString());
    }

    [Theory]
    [InlineData("Producer")]
    [InlineData("Trader")]
    [InlineData("Consumer")]
    public async Task Business_roles_cannot_review_or_list_admin_posts(string role)
    {
        using var client = fixture.CreateClient(); await NewAccount(client, role);
        using var list = await client.GetAsync("/api/v1/admin/posts"); Assert.Equal(HttpStatusCode.Forbidden, list.StatusCode);
        using var review = await client.PostAsJsonAsync($"/api/v1/admin/posts/{Guid.NewGuid()}/review",
            new { status = "Published", reason = "Invalid authority", expectedRevision = 1 });
        Assert.Equal(HttpStatusCode.Forbidden, review.StatusCode);
    }

    [Fact]
    public async Task Concurrent_reviews_only_commit_one_revision_history_and_audit()
    {
        using var author = fixture.CreateClient(); using var admin = fixture.CreateClient();
        var authorId = await NewAccount(author, "Producer"); await Login(admin, "admin@fruitvision.test");
        var id = (await Submit(author)).GetProperty("id").GetGuid();
        var replies = await Task.WhenAll(new[] { "Published", "Rejected" }.Select(status => admin.PostAsJsonAsync(
            $"/api/v1/admin/posts/{id}/review", new { status, reason = "Concurrent review", expectedRevision = 1 })));
        try
        {
            Assert.Single(replies, response => response.StatusCode == HttpStatusCode.OK);
            Assert.Single(replies, response => response.StatusCode == HttpStatusCode.Conflict);
            Assert.Equal(2, (await Get(author, $"/api/v1/posts/{id}")).GetProperty("revision").GetInt32());
            using var scope = fixture.Services.CreateScope(); var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
            Assert.Equal(1, await db.AuditEntries.CountAsync(item => item.SubjectId == authorId && item.Action == "PostReviewed"));
            Assert.Equal(1, await db.InteractionHistories.CountAsync(item => item.UserId == authorId && item.Kind == "PostReviewed"));
        }
        finally { foreach (var reply in replies) reply.Dispose(); }
    }

    [Fact]
    public async Task Invalid_transitions_stale_versions_and_unapproved_authors_do_not_publish()
    {
        using var author = fixture.CreateClient(); using var admin = fixture.CreateClient();
        var authorId = await NewAccount(author, "Producer"); await Login(admin, "admin@fruitvision.test");
        var id = (await Submit(author)).GetProperty("id").GetGuid();
        using var pause = await admin.PostAsJsonAsync($"/api/v1/admin/posts/{id}/review",
            new { status = "Paused", reason = "Cannot pause a draft", expectedRevision = 1 });
        Assert.Equal(HttpStatusCode.Conflict, pause.StatusCode);
        using var missingVersion = await admin.PostAsJsonAsync($"/api/v1/admin/posts/{id}/review", new { status = "Published", reason = "No version" });
        Assert.Equal(HttpStatusCode.BadRequest, missingVersion.StatusCode);
        await Review(admin, id, "Rejected", 1);
        using var terminal = await admin.PostAsJsonAsync($"/api/v1/admin/posts/{id}/review",
            new { status = "Published", reason = "Rejected is terminal", expectedRevision = 2 });
        Assert.Equal(HttpStatusCode.Conflict, terminal.StatusCode);
        var secondId = (await Submit(author)).GetProperty("id").GetGuid();
        using var unapproved = await admin.PostAsJsonAsync($"/api/v1/admin/applications/{authorId}/review", new { status = "NeedsInformation", reason = "Need more information" });
        Assert.Equal(HttpStatusCode.OK, unapproved.StatusCode);
        using var blocked = await admin.PostAsJsonAsync($"/api/v1/admin/posts/{secondId}/review", new { status = "Published", reason = "Not yet approved", expectedRevision = 1 });
        Assert.Equal(HttpStatusCode.Conflict, blocked.StatusCode);
    }

    [Fact]
    public async Task Public_feed_is_newest_first_and_after_resolves_the_visible_anchor()
    {
        using var author = fixture.CreateClient(); using var admin = fixture.CreateClient(); using var reader = fixture.CreateClient();
        await NewAccount(author, "Trader"); await Login(admin, "admin@fruitvision.test");
        var first = (await Submit(author)).GetProperty("id").GetGuid(); await Review(admin, first, "Published", 1);
        var second = (await Submit(author)).GetProperty("id").GetGuid(); await Review(admin, second, "Published", 1);
        var page = await Get(reader, "/api/v1/posts?limit=1"); Assert.Equal(second, page.GetProperty("items")[0].GetProperty("id").GetGuid());
        Assert.Equal(second, page.GetProperty("next").GetGuid());
        var next = await Get(reader, $"/api/v1/posts?limit=1&after={second}"); Assert.Equal(first, next.GetProperty("items")[0].GetProperty("id").GetGuid());
        using var invalid = await reader.GetAsync($"/api/v1/posts?after={Guid.NewGuid()}"); Assert.Equal(HttpStatusCode.BadRequest, invalid.StatusCode);
    }

    [Fact]
    public async Task Concurrent_contact_creates_exactly_one_private_two_party_thread_and_history()
    {
        using var author = fixture.CreateClient(); using var consumer = fixture.CreateClient(); using var admin = fixture.CreateClient(); using var outsider = fixture.CreateClient();
        var authorId = await NewAccount(author, "Producer"); var consumerId = await NewAccount(consumer, "Consumer");
        await NewAccount(outsider, "Trader"); await Login(admin, "admin@fruitvision.test");
        var postId = (await Submit(author)).GetProperty("id").GetGuid(); await Review(admin, postId, "Published", 1);
        var replies = await Task.WhenAll(Enumerable.Range(0, 8).Select(_ => consumer.PostAsJsonAsync($"/api/v1/posts/{postId}/conversations", new { })));
        try
        {
            Assert.Single(replies, response => response.StatusCode == HttpStatusCode.Created);
            Assert.All(replies, response => Assert.True(response.StatusCode is HttpStatusCode.OK or HttpStatusCode.Created));
            var ids = new List<Guid>(); foreach (var reply in replies) ids.Add((await reply.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("id").GetGuid());
            var id = Assert.Single(ids.Distinct());
            using var deniedRead = await outsider.GetAsync($"/api/v1/conversations/{id}/messages"); Assert.Equal(HttpStatusCode.NotFound, deniedRead.StatusCode);
            using var deniedSend = await outsider.PostAsJsonAsync($"/api/v1/conversations/{id}/messages", new { clientMessageId = Guid.NewGuid().ToString("N"), text = "Not a participant" });
            Assert.Equal(HttpStatusCode.NotFound, deniedSend.StatusCode);
            using var scope = fixture.Services.CreateScope(); var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
            Assert.Equal(1, await db.Conversations.CountAsync(item => item.PostId == postId));
            Assert.Equal(new[] { authorId, consumerId }.Order(), (await db.Participants.Where(item => item.ConversationId == id).Select(item => item.UserId).ToListAsync()).Order());
            Assert.Equal(2, await db.InteractionHistories.CountAsync(item => (item.UserId == authorId || item.UserId == consumerId) && item.Kind == "ConversationCreated"));
        }
        finally { foreach (var reply in replies) reply.Dispose(); }
    }

    [Fact]
    public async Task Contact_forbids_admin_self_pending_unpublished_and_arbitrary_participants()
    {
        using var author = fixture.CreateClient(); using var admin = fixture.CreateClient(); using var reader = fixture.CreateClient(); using var pending = fixture.CreateClient();
        await NewAccount(author, "Producer"); await NewAccount(reader, "Trader"); await NewAccount(pending, "Consumer", approve: false); await Login(admin, "admin@fruitvision.test");
        var id = (await Submit(author)).GetProperty("id").GetGuid(); var route = $"/api/v1/posts/{id}/conversations";
        using var draft = await reader.PostAsJsonAsync(route, new { }); Assert.Equal(HttpStatusCode.NotFound, draft.StatusCode);
        await Review(admin, id, "Published", 1);
        using var self = await author.PostAsJsonAsync(route, new { }); Assert.Equal(HttpStatusCode.Conflict, self.StatusCode);
        using var forbiddenAdmin = await admin.PostAsJsonAsync(route, new { }); Assert.Equal(HttpStatusCode.Forbidden, forbiddenAdmin.StatusCode);
        using var pendingContact = await pending.PostAsJsonAsync(route, new { }); Assert.Equal(HttpStatusCode.Forbidden, pendingContact.StatusCode);
        using var injection = await reader.PostAsJsonAsync(route, new { participantIds = new[] { Guid.NewGuid() } }); Assert.Equal(HttpStatusCode.BadRequest, injection.StatusCode);
        using var privateDetail = await reader.GetAsync($"/api/v1/posts/{(await Submit(author)).GetProperty("id").GetGuid()}"); Assert.Equal(HttpStatusCode.NotFound, privateDetail.StatusCode);
    }

    [Fact]
    public async Task Contact_reuses_only_an_exact_two_party_legacy_thread()
    {
        using var author = fixture.CreateClient(); using var reader = fixture.CreateClient(); using var admin = fixture.CreateClient();
        var authorId = await NewAccount(author, "Producer"); var readerId = await NewAccount(reader, "Consumer"); await Login(admin, "admin@fruitvision.test");
        var postId = (await Submit(author)).GetProperty("id").GetGuid(); await Review(admin, postId, "Published", 1);
        var legacyId = Guid.NewGuid();
        using (var scope = fixture.Services.CreateScope())
        {
            var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
            db.Conversations.Add(new Conversation { Id = legacyId, PostId = postId, Title = "Existing private conversation" });
            db.Participants.AddRange(new Participant { ConversationId = legacyId, UserId = authorId }, new Participant { ConversationId = legacyId, UserId = readerId });
            await db.SaveChangesAsync();
        }
        using var response = await reader.PostAsJsonAsync($"/api/v1/posts/{postId}/conversations", new { }); Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        Assert.Equal(legacyId, (await response.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("id").GetGuid());
    }

    [Fact]
    public async Task Approved_branch_posts_validate_prices_purpose_and_dates()
    {
        using var producer = fixture.CreateClient(); using var trader = fixture.CreateClient();
        await NewAccount(producer, "Producer"); await NewAccount(trader, "Trader");
        var supply = await Submit(producer); var demand = await Submit(trader);
        Assert.Equal("Supply", supply.GetProperty("purpose").GetString()); Assert.Equal("Demand", demand.GetProperty("purpose").GetString());
        Assert.Equal("Đồng Tháp", demand.GetProperty("region").GetString()); Assert.Equal(JsonValueKind.Null, demand.GetProperty("priceMinVndPerKg").ValueKind);
        var body = new Dictionary<string, object?> { ["title"] = "Local mango information", ["body"] = "Estimated availability for discussion only.", ["productCode"] = "mango", ["estimatedQuantityKg"] = 20, ["branchId"] = branches[producer] };
        foreach (var extra in new Dictionary<string, object?>[] {
            new() { ["purpose"] = "Demand" }, new() { ["priceMinVndPerKg"] = 10000 },
            new() { ["priceMinVndPerKg"] = 20000, ["priceMaxVndPerKg"] = 10000 },
            new() { ["availableOn"] = DateOnly.FromDateTime(DateTime.UtcNow).AddYears(3) } })
        {
            using var invalid = await producer.PostAsJsonAsync("/api/v1/posts", body.Concat(extra).ToDictionary(pair => pair.Key, pair => pair.Value));
            Assert.Equal(HttpStatusCode.BadRequest, invalid.StatusCode);
        }
        body["purpose"] = "Supply"; body["priceMinVndPerKg"] = 10000; body["priceMaxVndPerKg"] = 15000;
        body["branchId"] = branches[trader]; body["availableOn"] = DateOnly.FromDateTime(DateTime.UtcNow).AddDays(1);
        using var valid = await trader.PostAsJsonAsync("/api/v1/posts", body); Assert.Equal(HttpStatusCode.Created, valid.StatusCode);
        Assert.Equal(15000m, (await valid.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("priceMaxVndPerKg").GetDecimal());
    }

    [Fact]
    public async Task Four_role_hubs_receive_public_visibility_events_but_private_contact_events_only_reach_participants()
    {
        using var author = fixture.CreateClient(); using var consumer = fixture.CreateClient(); using var trader = fixture.CreateClient(); using var admin = fixture.CreateClient();
        await NewAccount(author, "Producer"); await NewAccount(consumer, "Consumer"); await NewAccount(trader, "Trader"); await Login(admin, "admin@fruitvision.test");
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(20));
        using var authorHub = await OpenHub(author, timeout.Token); using var consumerHub = await OpenHub(consumer, timeout.Token);
        using var traderHub = await OpenHub(trader, timeout.Token); using var adminHub = await OpenHub(admin, timeout.Token);
        var id = (await Submit(author)).GetProperty("id").GetGuid();
        await authorHub.Event("PostChanged", timeout.Token); await adminHub.Event("PostChanged", timeout.Token);
        await Review(admin, id, "Published", 1);
        foreach (var hub in new[] { authorHub, adminHub, consumerHub, traderHub })
        {
            var changed = await hub.Event("PublishedPostChanged", timeout.Token, hub == consumerHub || hub == traderHub ? "PostChanged" : null);
            Assert.Equal(id, changed.GetProperty("postId").GetGuid());
            Assert.Equal(new[] { "eventId", "postId", "revision", "status" }, changed.EnumerateObject().Select(property => property.Name).Order());
        }
        using var contact = await consumer.PostAsJsonAsync($"/api/v1/posts/{id}/conversations", new { }); Assert.Equal(HttpStatusCode.Created, contact.StatusCode);
        var conversationId = (await contact.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("id").GetGuid();
        Assert.Equal(conversationId, (await authorHub.Event("ConversationCreated", timeout.Token)).GetProperty("id").GetGuid());
        Assert.Equal(conversationId, (await consumerHub.Event("ConversationCreated", timeout.Token)).GetProperty("id").GetGuid());
        await traderHub.NoEvent("ConversationCreated"); await adminHub.NoEvent("ConversationCreated");
    }

    [Fact]
    public async Task A_departed_group_member_is_excluded_from_message_dispatch_even_with_stale_hub_group()
    {
        using var owner = fixture.CreateClient(); using var member = fixture.CreateClient();
        await NewAccount(owner, "Producer"); await NewAccount(member, "Consumer");
        using var created = await owner.PostAsJsonAsync("/api/v1/community/groups", new { title = "Fresh membership dispatch", region = "Đồng Tháp", productCode = "mango" });
        Assert.Equal(HttpStatusCode.Created, created.StatusCode); var id = (await created.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("id").GetGuid();
        using var joined = await member.PostAsJsonAsync($"/api/v1/community/groups/{id}/join", new { }); Assert.True(joined.IsSuccessStatusCode);
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(15));
        using var ownerHub = await OpenHub(owner, timeout.Token); using var memberHub = await OpenHub(member, timeout.Token);
        await memberHub.Join(id, timeout.Token);
        using var left = await member.PostAsJsonAsync($"/api/v1/community/groups/{id}/leave", new { }); Assert.True(left.IsSuccessStatusCode);
        using var sent = await owner.PostAsJsonAsync($"/api/v1/conversations/{id}/messages", new { clientMessageId = Guid.NewGuid().ToString("N"), text = "Only current members may receive this message." });
        Assert.Equal(HttpStatusCode.Created, sent.StatusCode);
        await ownerHub.Event("MessageCreated", timeout.Token);
        await memberHub.NoEvent("MessageCreated");
        using var closed = await owner.PostAsJsonAsync($"/api/v1/community/groups/{id}/close", new { }); Assert.True(closed.IsSuccessStatusCode);
        using var blocked = await owner.PostAsJsonAsync($"/api/v1/conversations/{id}/messages", new { clientMessageId = Guid.NewGuid().ToString("N"), text = "Cannot send new messages after close." });
        Assert.Equal(HttpStatusCode.Conflict, blocked.StatusCode);
    }

    [Fact]
    public async Task Authorized_group_messages_and_hub_events_identify_two_senders_without_private_profile_fields()
    {
        using var producer = fixture.CreateClient(); using var trader = fixture.CreateClient(); using var outsider = fixture.CreateClient();
        var producerId = await NewAccount(producer, "Producer", displayName: "Producer sender");
        var traderId = await NewAccount(trader, "Trader", displayName: "Trader sender");
        await NewAccount(outsider, "Consumer");
        using var created = await producer.PostAsJsonAsync("/api/v1/community/groups", new { title = "Identifiable group speakers", region = "Đồng Tháp", productCode = "mango" });
        Assert.Equal(HttpStatusCode.Created, created.StatusCode);
        var conversationId = (await created.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("id").GetGuid();
        using var joined = await trader.PostAsJsonAsync($"/api/v1/community/groups/{conversationId}/join", new { }); Assert.True(joined.IsSuccessStatusCode);
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(15)); using var hub = await OpenHub(producer, timeout.Token);
        var route = $"/api/v1/conversations/{conversationId}/messages";
        var firstKey = Guid.NewGuid().ToString("N"); var secondKey = Guid.NewGuid().ToString("N");
        using var first = await producer.PostAsJsonAsync(route, new { clientMessageId = firstKey, text = "Producer availability message" });
        using var second = await trader.PostAsJsonAsync(route, new { clientMessageId = secondKey, text = "Trader interest message" });
        Assert.Equal(HttpStatusCode.Created, first.StatusCode); Assert.Equal(HttpStatusCode.Created, second.StatusCode);
        var firstMessage = await first.Content.ReadFromJsonAsync<JsonElement>(); var secondMessage = await second.Content.ReadFromJsonAsync<JsonElement>();
        AssertSender(firstMessage, producerId, "Producer sender", "Producer"); AssertSender(secondMessage, traderId, "Trader sender", "Trader");
        using var retry = await trader.PostAsJsonAsync(route, new { clientMessageId = secondKey, text = "Trader interest message" }); Assert.Equal(HttpStatusCode.OK, retry.StatusCode);
        AssertSender(await retry.Content.ReadFromJsonAsync<JsonElement>(), traderId, "Trader sender", "Trader");
        var history = await Get(producer, route);
        AssertSender(history.GetProperty("items").EnumerateArray().Single(message => message.GetProperty("id").GetGuid() == firstMessage.GetProperty("id").GetGuid()), producerId, "Producer sender", "Producer");
        AssertSender(history.GetProperty("items").EnumerateArray().Single(message => message.GetProperty("id").GetGuid() == secondMessage.GetProperty("id").GetGuid()), traderId, "Trader sender", "Trader");
        var deliveredIds = new HashSet<Guid>();
        while (deliveredIds.Count < 2)
        {
            var delivered = await hub.Event("MessageCreated", timeout.Token);
            deliveredIds.Add(delivered.GetProperty("id").GetGuid());
            if (delivered.GetProperty("senderId").GetGuid() == producerId) AssertSender(delivered, producerId, "Producer sender", "Producer");
            else AssertSender(delivered, traderId, "Trader sender", "Trader");
        }
        using var deniedRead = await outsider.GetAsync(route); Assert.Equal(HttpStatusCode.NotFound, deniedRead.StatusCode);
        using var deniedSend = await outsider.PostAsJsonAsync(route, new { clientMessageId = Guid.NewGuid().ToString("N"), text = "Not a member" }); Assert.Equal(HttpStatusCode.NotFound, deniedSend.StatusCode);
    }

    private static void AssertSender(JsonElement message, Guid id, string name, string role)
    {
        Assert.Equal(id, message.GetProperty("senderId").GetGuid());
        Assert.True(message.TryGetProperty("sender", out var sender), "Authorized messages need public sender metadata.");
        Assert.Equal(id, sender.GetProperty("id").GetGuid()); Assert.Equal(name, sender.GetProperty("displayName").GetString()); Assert.Equal(role, sender.GetProperty("role").GetString());
        Assert.Equal(new[] { "displayName", "id", "role" }, sender.EnumerateObject().Select(property => property.Name).Order());
    }

    private async Task<HubSession> OpenHub(HttpClient client, CancellationToken cancellationToken)
    {
        var connector = fixture.Server.CreateWebSocketClient();
        connector.ConfigureRequest = request => request.Headers.Authorization = "Bearer " + client.DefaultRequestHeaders.Authorization!.Parameter;
        var socket = await connector.ConnectAsync(new Uri("ws://localhost/hubs/fruitvision"), cancellationToken);
        var session = new HubSession(socket); await session.Send(new { protocol = "json", version = 1 }, cancellationToken);
        var hello = await session.Read(cancellationToken); Assert.False(hello.TryGetProperty("error", out _)); return session;
    }

    private sealed class HubSession(WebSocket socket) : IDisposable
    {
        private readonly Queue<JsonElement> pending = new();
        public async Task Send(object body, CancellationToken cancellationToken) =>
            await socket.SendAsync(Encoding.UTF8.GetBytes(JsonSerializer.Serialize(body) + "\u001e"), WebSocketMessageType.Text, true, cancellationToken);
        public async Task<JsonElement> Read(CancellationToken cancellationToken)
        {
            while (pending.Count == 0)
            {
                using var data = new MemoryStream(); var buffer = new byte[8192];
                while (true)
                {
                    var part = await socket.ReceiveAsync(buffer, cancellationToken);
                    if (part.MessageType == WebSocketMessageType.Close) throw new WebSocketException("Unexpected hub close.");
                    data.Write(buffer, 0, part.Count); if (part.EndOfMessage) break;
                }
                foreach (var record in Encoding.UTF8.GetString(data.ToArray()).Split('\u001e', StringSplitOptions.RemoveEmptyEntries))
                { using var document = JsonDocument.Parse(record); pending.Enqueue(document.RootElement.Clone()); }
            }
            return pending.Dequeue();
        }
        public async Task<JsonElement> Event(string target, CancellationToken cancellationToken, string? forbiddenTarget = null)
        {
            while (true)
            {
                var frame = await Read(cancellationToken);
                if (!frame.TryGetProperty("target", out var name)) continue;
                Assert.False(name.GetString() == forbiddenTarget, "Private event was delivered outside its authorized group.");
                if (name.GetString() == target) return frame.GetProperty("arguments")[0];
            }
        }
        public async Task Join(Guid id, CancellationToken cancellationToken)
        {
            await Send(new { type = 1, invocationId = "join", target = "JoinConversation", arguments = new[] { id } }, cancellationToken);
            while (true) { var frame = await Read(cancellationToken); if (frame.TryGetProperty("invocationId", out _)) { Assert.False(frame.TryGetProperty("error", out _)); return; } }
        }
        public async Task NoEvent(string target)
        {
            using var timeout = new CancellationTokenSource(TimeSpan.FromMilliseconds(400));
            try { await Event(target, timeout.Token); Assert.Fail("Unauthorized event was delivered."); }
            catch (OperationCanceledException) when (timeout.IsCancellationRequested) { }
        }
        public void Dispose() => socket.Dispose();
    }

    private async Task<Guid> NewAccount(HttpClient client, string role, bool approve = true, string displayName = "Workflow test")
    {
        var account = await TestAccounts.CreateAsync(fixture.Services,fixture.Password,role,approve,displayName);
        branches[client] = account.BranchId;
        await Login(client, account.Email); return account.Id;
    }
    private async Task Login(HttpClient client, string email)
    {
        using var response = await client.PostAsJsonAsync("/api/v1/auth/login", new { email, password = fixture.Password }); Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", (await response.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("accessToken").GetString());
    }
    private async Task<JsonElement> Submit(HttpClient client)
    {
        using var response = await client.PostAsJsonAsync("/api/v1/posts", new { title = "Fresh mango forecast", body = "A future survey estimate, without any stock commitment.", productCode = "mango", estimatedQuantityKg = 20, branchId = branches[client] }); Assert.Equal(HttpStatusCode.Created, response.StatusCode); return await response.Content.ReadFromJsonAsync<JsonElement>();
    }
    private static async Task<JsonElement> Review(HttpClient client, Guid id, string status, int revision)
    {
        using var response = await client.PostAsJsonAsync($"/api/v1/admin/posts/{id}/review", new { status, reason = "Reviewed for integration test", expectedRevision = revision }); Assert.Equal(HttpStatusCode.OK, response.StatusCode); return await response.Content.ReadFromJsonAsync<JsonElement>();
    }
    private static async Task<JsonElement> Get(HttpClient client, string path)
    { using var response = await client.GetAsync(path); Assert.Equal(HttpStatusCode.OK, response.StatusCode); return await response.Content.ReadFromJsonAsync<JsonElement>(); }
}
