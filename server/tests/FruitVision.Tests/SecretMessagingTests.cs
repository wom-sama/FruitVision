using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Net.WebSockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using FruitVision.Api.Auth;
using FruitVision.Api.Data;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Identity;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Xunit;

namespace FruitVision.Tests;

[Collection("Api")]
public sealed class SecretMessagingTests(ApiFixture fixture)
{
    private const string Base = "/api/v1/secret";

    [Theory]
    [InlineData("Producer", "Producer")]
    [InlineData("Producer", "Trader")]
    [InlineData("Trader", "Trader")]
    public async Task Direct_secret_thread_is_created_once_for_exact_two_sellers_and_outsiders_are_hidden(string firstRole, string secondRole)
    {
        using var app = App();
        using var first = await User(app, firstRole);
        using var second = await User(app, secondRole);
        using var outsider = await User(app);
        await Register(first); await Register(second);
        var direct = await Direct(app, first.Id, second.Id);
        var requests = await Task.WhenAll(first.Http.PostAsJsonAsync(Base + "/conversations", new { directConversationId = direct }), second.Http.PostAsJsonAsync(Base + "/conversations", new { directConversationId = direct }));
        Assert.Single(requests, r => r.StatusCode == HttpStatusCode.Created);
        Assert.Single(requests, r => r.StatusCode == HttpStatusCode.OK);
        var id = (await requests[0].Content.ReadFromJsonAsync<JsonElement>()).GetProperty("id").GetGuid();
        Assert.Equal(id, (await requests[1].Content.ReadFromJsonAsync<JsonElement>()).GetProperty("id").GetGuid());
        using var detail = await outsider.Http.GetAsync(Base + "/conversations/" + id);
        using var bundles = await outsider.Http.GetAsync(Base + "/conversations/" + id + "/bundles");
        using var join = await outsider.Http.PostAsJsonAsync(Base + "/conversations", new { directConversationId = direct });
        Assert.Equal(HttpStatusCode.NotFound, detail.StatusCode); Assert.Equal(HttpStatusCode.NotFound, bundles.StatusCode); Assert.Equal(HttpStatusCode.NotFound, join.StatusCode);
        var group = await Direct(app, first.Id, second.Id, "Group");
        using var deniedGroup = await first.Http.PostAsJsonAsync(Base + "/conversations", new { directConversationId = group });
        Assert.Equal(HttpStatusCode.NotFound, deniedGroup.StatusCode);
        using (var scope = app.Services.CreateScope())
        {
            var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
            db.Participants.Add(new Participant { ConversationId = direct, UserId = outsider.Id });
            await db.SaveChangesAsync();
        }
        using var changedMembership = await first.Http.GetAsync(Base + "/conversations/" + id);
        Assert.Equal(HttpStatusCode.NotFound, changedMembership.StatusCode);
        foreach (var response in requests) response.Dispose();
    }

    [Theory]
    [InlineData("Consumer")]
    [InlineData("Admin")]
    public async Task Secret_feature_has_no_consumer_or_admin_override(string role)
    {
        using var app = App(); using var user = await User(app, role);
        foreach (var route in new[] { "/devices", "/conversations" })
        {
            using var response = await user.Http.GetAsync(Base + route);
            Assert.Equal(HttpStatusCode.Forbidden, response.StatusCode);
        }
        using var register = await user.Http.PostAsJsonAsync(Base + "/devices", Bundle(Guid.NewGuid()));
        Assert.Equal(HttpStatusCode.Forbidden, register.StatusCode);
    }

    [Fact]
    public async Task Device_enrollment_is_fresh_strong_verified_one_active_and_revoked_ids_are_never_reused()
    {
        using var app = App();
        foreach (var state in new[] { (Method: "password", Age: 0, Verified: true), (Method: "password_email_otp", Age: 16, Verified: true), (Method: "password_totp", Age: 0, Verified: false) })
        {
            using var weak = await User(app, method: state.Method, age: state.Age, verified: state.Verified);
            using var denied = await weak.Http.PostAsJsonAsync(Base + "/devices", Bundle(Guid.NewGuid()));
            Assert.Equal(HttpStatusCode.Forbidden, denied.StatusCode);
        }
        using var user = await User(app);
        var ids = new[] { Guid.NewGuid(), Guid.NewGuid() };
        var attempts = await Task.WhenAll(ids.Select(id => user.Http.PostAsJsonAsync(Base + "/devices", Bundle(id))));
        Assert.Single(attempts, response => response.StatusCode == HttpStatusCode.Created);
        Assert.Single(attempts, response => response.StatusCode == HttpStatusCode.Conflict);
        var enrolled = await attempts.Single(response => response.StatusCode == HttpStatusCode.Created).Content.ReadFromJsonAsync<JsonElement>();
        var old = enrolled.GetProperty("deviceId").GetGuid();
        using var same = await user.Http.PostAsJsonAsync(Base + "/devices", new { deviceId = old, label = "Opaque test device", encryptionPublicKey = enrolled.GetProperty("encryptionPublicKey").GetString(), signingPublicKey = enrolled.GetProperty("signingPublicKey").GetString() });
        Assert.Equal(HttpStatusCode.OK, same.StatusCode);
        using var mutation = await user.Http.PostAsJsonAsync(Base + "/devices", Bundle(old)); Assert.Equal(HttpStatusCode.Conflict, mutation.StatusCode);
        using var revoke = await user.Http.DeleteAsync(Base + "/devices/" + old); Assert.Equal(HttpStatusCode.NoContent, revoke.StatusCode);
        using var reuse = await user.Http.PostAsJsonAsync(Base + "/devices", Bundle(old)); Assert.Equal(HttpStatusCode.Conflict, reuse.StatusCode);
        var next = await Register(user); Assert.Equal(2, next.GetProperty("version").GetInt32());
        foreach (var response in attempts) response.Dispose();
    }

    [Fact]
    public async Task Message_replay_is_bound_to_cipher_bytes_and_each_device_sees_only_its_own_envelope()
    {
        using var app = App(); using var first = await User(app); using var second = await User(app, "Trader");
        var (id, a, b) = await Thread(app, first, second);
        var ownCipher = Cipher(); var peerCipher = Cipher(); var key = Guid.NewGuid();
        var packet = Message(key, a, b, ownCipher, peerCipher);
        using var sent = await first.Http.PostAsJsonAsync(Path(id, "/messages"), packet); Assert.Equal(HttpStatusCode.Created, sent.StatusCode);
        var message = await sent.Content.ReadFromJsonAsync<JsonElement>();
        Assert.Equal(ownCipher, message.GetProperty("envelope").GetProperty("ciphertextBase64").GetString());
        using var replay = await first.Http.PostAsJsonAsync(Path(id, "/messages"), packet); Assert.Equal(HttpStatusCode.OK, replay.StatusCode);
        Assert.Equal(message.GetProperty("id").GetGuid(), (await replay.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("id").GetGuid());
        using var changed = await first.Http.PostAsJsonAsync(Path(id, "/messages"), Message(key, a, b, ownCipher, Cipher())); Assert.Equal(HttpStatusCode.Conflict, changed.StatusCode);
        var own = await Get(first, Path(id, "/messages?deviceId=" + a));
        var peer = await Get(second, Path(id, "/messages?deviceId=" + b));
        Assert.Equal(ownCipher, own.GetProperty("items")[0].GetProperty("envelope").GetProperty("ciphertextBase64").GetString());
        Assert.DoesNotContain(peerCipher, own.GetRawText()); Assert.DoesNotContain(ownCipher, peer.GetRawText());
        using var wrongDevice = await first.Http.GetAsync(Path(id, "/messages?deviceId=" + b)); Assert.Equal(HttpStatusCode.NotFound, wrongDevice.StatusCode);
        using var scope = app.Services.CreateScope(); var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
        Assert.Equal(1, await db.Set<SecretMessage>().CountAsync(m => m.ConversationId == id));
        Assert.Equal(2, await db.Set<SecretEnvelope>().CountAsync(e => e.MessageId == message.GetProperty("id").GetGuid()));
        var ordinaryId = await db.Set<SecretConversation>().Where(c => c.Id == id).Select(c => c.DirectConversationId).SingleAsync();
        Assert.Equal(0, await db.Messages.CountAsync(m => m.ConversationId == ordinaryId));
    }

    [Fact]
    public async Task Plaintext_fields_bad_base64_wrong_recipients_and_oversized_ciphertext_are_rejected()
    {
        using var app = App(); using var first = await User(app); using var second = await User(app);
        var (id, a, b) = await Thread(app, first, second);
        using var plaintext = await first.Http.PostAsJsonAsync(Path(id, "/messages"), new { clientMessageId = Guid.NewGuid(), senderDeviceId = a, text = "must never be accepted", envelopes = new[] { new { recipientDeviceId = a, ciphertextBase64 = Cipher() }, new { recipientDeviceId = b, ciphertextBase64 = Cipher() } } });
        Assert.Equal(HttpStatusCode.BadRequest, plaintext.StatusCode);
        using var duplicate = await first.Http.PostAsJsonAsync(Path(id, "/messages"), Message(Guid.NewGuid(), a, a, Cipher(), Cipher())); Assert.Equal(HttpStatusCode.BadRequest, duplicate.StatusCode);
        using var malformed = await first.Http.PostAsJsonAsync(Path(id, "/messages"), Message(Guid.NewGuid(), a, b, "bad!", Cipher())); Assert.Equal(HttpStatusCode.BadRequest, malformed.StatusCode);
        using var tooLarge = await first.Http.PostAsJsonAsync(Path(id, "/messages"), Message(Guid.NewGuid(), a, b, Cipher(16385), Cipher())); Assert.Equal(HttpStatusCode.BadRequest, tooLarge.StatusCode);
        using var wrongPeer = await first.Http.PostAsJsonAsync(Path(id, "/messages"), Message(Guid.NewGuid(), a, Guid.NewGuid(), Cipher(), Cipher())); Assert.Equal(HttpStatusCode.Conflict, wrongPeer.StatusCode);
        using var boundary = await first.Http.PostAsJsonAsync(Path(id, "/messages"), Message(Guid.NewGuid(), a, b, Cipher(16384), Cipher(16384))); Assert.Equal(HttpStatusCode.Created, boundary.StatusCode);
    }

    [Fact]
    public async Task Sequences_are_atomic_and_support_latest_older_and_forward_catchup()
    {
        using var app = App(); using var first = await User(app); using var second = await User(app);
        var (id, a, b) = await Thread(app, first, second);
        var sends = await Task.WhenAll(Enumerable.Range(0, 5).Select(_ => first.Http.PostAsJsonAsync(Path(id, "/messages"), Message(Guid.NewGuid(), a, b, Cipher(), Cipher()))));
        Assert.All(sends, response => Assert.Equal(HttpStatusCode.Created, response.StatusCode));
        var latest = await Get(second, Path(id, $"/messages?deviceId={b}&limit=2"));
        Assert.Equal(new long[] { 4, 5 }, latest.GetProperty("items").EnumerateArray().Select(row => row.GetProperty("sequence").GetInt64()));
        var older = await Get(second, Path(id, $"/messages?deviceId={b}&limit=2&beforeSequence=4"));
        Assert.Equal(new long[] { 2, 3 }, older.GetProperty("items").EnumerateArray().Select(row => row.GetProperty("sequence").GetInt64()));
        var catchup = await Get(second, Path(id, $"/messages?deviceId={b}&limit=2&afterSequence=0"));
        Assert.Equal(new long[] { 1, 2 }, catchup.GetProperty("items").EnumerateArray().Select(row => row.GetProperty("sequence").GetInt64()));
        Assert.Equal(2, catchup.GetProperty("nextAfter").GetInt64());
        foreach (var response in sends) response.Dispose();
    }

    [Fact]
    public async Task Cipher_attachment_is_private_opaque_bounded_and_revocation_blocks_original_snapshot_device()
    {
        using var app = App(); using var first = await User(app); using var second = await User(app); using var outsider = await User(app);
        var (id, a, b) = await Thread(app, first, second); var ciphertext = RandomNumberGenerator.GetBytes(1024);
        using var upload = await Upload(first, id, a, b, ciphertext); Assert.Equal(HttpStatusCode.Created, upload.StatusCode);
        var attachment = await upload.Content.ReadFromJsonAsync<JsonElement>(); var aid = attachment.GetProperty("id").GetGuid();
        var target = Path(id, $"/attachments/{aid}?deviceId={b}");
        using var download = await second.Http.GetAsync(target); Assert.Equal(HttpStatusCode.OK, download.StatusCode); Assert.Equal(ciphertext, await download.Content.ReadAsByteArrayAsync());
        Assert.Equal("application/octet-stream", download.Content.Headers.ContentType?.MediaType);
        using var hidden = await outsider.Http.GetAsync(target); Assert.Equal(HttpStatusCode.NotFound, hidden.StatusCode);
        using var huge = await Upload(first, id, a, b, new byte[5308417]); Assert.Equal(HttpStatusCode.RequestEntityTooLarge, huge.StatusCode);
        using var revoke = await second.Http.DeleteAsync(Base + "/devices/" + b); Assert.Equal(HttpStatusCode.NoContent, revoke.StatusCode);
        using var revoked = await second.Http.GetAsync(target); Assert.Equal(HttpStatusCode.NotFound, revoked.StatusCode);
        using var staleSend = await first.Http.PostAsJsonAsync(Path(id, "/messages"), Message(Guid.NewGuid(), a, b, Cipher(), Cipher())); Assert.Equal(HttpStatusCode.Conflict, staleSend.StatusCode);
        var fresh = (await Register(second)).GetProperty("deviceId").GetGuid();
        using var noRecovery = await second.Http.GetAsync(Path(id, $"/attachments/{aid}?deviceId={fresh}")); Assert.Equal(HttpStatusCode.NotFound, noRecovery.StatusCode);
    }

    [Fact]
    public async Task Notifications_are_metadata_only_and_do_not_reach_an_unrelated_seller()
    {
        using var app = App(); using var first = await User(app); using var second = await User(app); using var outsider = await User(app);
        var (id, a, b) = await Thread(app, first, second);
        using var recipient = await Hub(app, second.Access); using var unrelated = await Hub(app, outsider.Access);
        using var sent = await first.Http.PostAsJsonAsync(Path(id, "/messages"), Message(Guid.NewGuid(), a, b, Cipher(), Cipher())); Assert.Equal(HttpStatusCode.Created, sent.StatusCode);
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(3)); var frame = await Event(recipient, timeout.Token);
        var metadata = frame.GetProperty("arguments")[0];
        Assert.Equal(id, metadata.GetProperty("conversationId").GetGuid());
        Assert.Equal(new[] { "conversationId", "eventId", "id", "sequence" }, metadata.EnumerateObject().Select(p => p.Name).Order().ToArray());
        using var absent = new CancellationTokenSource(300);
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => Event(unrelated, absent.Token));
    }

    [Fact]
    public async Task Secret_upload_shares_user_storage_quota_with_registered_normal_images()
    {
        using var app = App(new Dictionary<string, string?> { ["MediaLimits:UserStoredBytes"] = "1024", ["MediaLimits:MinimumFreeDiskBytes"] = "1" });
        using var first = await User(app); using var second = await User(app);
        var (id, a, b) = await Thread(app, first, second);
        using (var scope = app.Services.CreateScope())
        {
            var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
            db.Add(new NormalImage { OwnerId = first.Id, Width = 1, Height = 1, SizeBytes = 900, RawSha256 = new string('a', 64), Sha256 = new string('b', 64) });
            await db.SaveChangesAsync();
        }
        using var boundary = await Upload(first, id, a, b, RandomNumberGenerator.GetBytes(124)); Assert.Equal(HttpStatusCode.Created, boundary.StatusCode);
        using var excess = await Upload(first, id, a, b, new byte[] { 1 }); Assert.Equal(HttpStatusCode.Conflict, excess.StatusCode);
        using var check = app.Services.CreateScope(); var context = check.ServiceProvider.GetRequiredService<AppDbContext>();
        Assert.Equal(1, await context.Set<SecretAttachment>().CountAsync(attachment => attachment.ConversationId == id));
    }

    private WebApplicationFactory<Program> App(Dictionary<string, string?>? settings = null)
    {
        settings ??= new(); settings["SecretMessages:RootPath"] = System.IO.Path.GetFullPath(System.IO.Path.Combine(AppContext.BaseDirectory, "../../../../../.local/secret-tests", Guid.NewGuid().ToString("N")));
        return fixture.WithWebHostBuilder(builder => builder.ConfigureAppConfiguration((_, c) => c.AddInMemoryCollection(settings)));
    }
    private async Task<Identity> User(WebApplicationFactory<Program> app, string role = "Producer", string method = "password_email_otp", int age = 0, bool verified = true)
    {
        var email = $"secret.{Guid.NewGuid():N}@fruitvision.test"; var user = new AppUser { Id = Guid.NewGuid(), UserName = email, Email = email, EmailConfirmed = verified, DisplayName = "Opaque fixture", Role = Enum.Parse<AccountRole>(role), ApprovalStatus = ApprovalState.Approved, IsActive = true };
        using var scope = app.Services.CreateScope(); Assert.True((await scope.ServiceProvider.GetRequiredService<UserManager<AppUser>>().CreateAsync(user, fixture.Password)).Succeeded);
        var db = scope.ServiceProvider.GetRequiredService<AppDbContext>(); var (session, access, _) = SessionTokens.Create(user, method); session.CreatedAt = DateTimeOffset.UtcNow.AddMinutes(-age); db.Add(session); await db.SaveChangesAsync();
        var client = app.CreateClient(); client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", access); return new(user.Id, access, client);
    }
    // Backend validates opaque public-key lengths only; these fixtures do not claim client crypto tests.
    private static object Bundle(Guid id) => new { deviceId = id, label = "Opaque test device", encryptionPublicKey = Cipher(32), signingPublicKey = Cipher(32) };
    private static string Cipher(int bytes = 128) => Convert.ToBase64String(RandomNumberGenerator.GetBytes(bytes));
    private static object Message(Guid key, Guid a, Guid b, string own, string peer) => new { clientMessageId = key, senderDeviceId = a, envelopes = new[] { new { recipientDeviceId = a, ciphertextBase64 = own }, new { recipientDeviceId = b, ciphertextBase64 = peer } } };
    private static string Path(Guid id, string suffix = "") => Base + "/conversations/" + id + suffix;
    private static async Task<JsonElement> Register(Identity user) { using var response = await user.Http.PostAsJsonAsync(Base + "/devices", Bundle(Guid.NewGuid())); Assert.Equal(HttpStatusCode.Created, response.StatusCode); return await response.Content.ReadFromJsonAsync<JsonElement>(); }
    private static async Task<Guid> Direct(WebApplicationFactory<Program> app, Guid a, Guid b, string kind = "Direct") { using var scope = app.Services.CreateScope(); var db = scope.ServiceProvider.GetRequiredService<AppDbContext>(); var direct = new Conversation { Kind = kind, Title = "Existing ordinary context" }; db.Add(direct); db.AddRange(new Participant { ConversationId = direct.Id, UserId = a }, new Participant { ConversationId = direct.Id, UserId = b }); await db.SaveChangesAsync(); return direct.Id; }
    private static async Task<(Guid Id, Guid A, Guid B)> Thread(WebApplicationFactory<Program> app, Identity a, Identity b) { var first = (await Register(a)).GetProperty("deviceId").GetGuid(); var second = (await Register(b)).GetProperty("deviceId").GetGuid(); var direct = await Direct(app, a.Id, b.Id); using var response = await a.Http.PostAsJsonAsync(Base + "/conversations", new { directConversationId = direct }); Assert.Equal(HttpStatusCode.Created, response.StatusCode); return ((await response.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("id").GetGuid(), first, second); }
    private static async Task<JsonElement> Get(Identity user, string path) { using var response = await user.Http.GetAsync(path); Assert.Equal(HttpStatusCode.OK, response.StatusCode); return await response.Content.ReadFromJsonAsync<JsonElement>(); }
    private static Task<HttpResponseMessage> Upload(Identity user, Guid id, Guid own, Guid peer, byte[] bytes) { var body = new ByteArrayContent(bytes); body.Headers.ContentType = new("application/octet-stream"); return user.Http.PostAsync(Path(id, $"/attachments?senderDeviceId={own}&recipientDeviceId={peer}"), body); }
    private static async Task<WebSocket> Hub(WebApplicationFactory<Program> app, string access) { using var budget = new CancellationTokenSource(TimeSpan.FromSeconds(3)); var client = app.Server.CreateWebSocketClient(); client.ConfigureRequest = request => request.Headers.Authorization = "Bearer " + access; var socket = await client.ConnectAsync(new Uri("ws://localhost/hubs/fruitvision"), budget.Token); await socket.SendAsync(new ArraySegment<byte>(Encoding.UTF8.GetBytes("{\"protocol\":\"json\",\"version\":1}\u001e")), WebSocketMessageType.Text, true, budget.Token); await Receive(socket, budget.Token); return socket; }
    private static async Task<string> Receive(WebSocket socket, CancellationToken ct) { var buffer = new byte[8192]; using var output = new MemoryStream(); WebSocketReceiveResult result; do { result = await socket.ReceiveAsync(new ArraySegment<byte>(buffer), ct); output.Write(buffer, 0, result.Count); } while (!result.EndOfMessage); return Encoding.UTF8.GetString(output.ToArray()); }
    private static async Task<JsonElement> Event(WebSocket socket, CancellationToken ct) { while (true) foreach (var raw in (await Receive(socket, ct)).Split('\u001e', StringSplitOptions.RemoveEmptyEntries)) { using var json = JsonDocument.Parse(raw); if (json.RootElement.TryGetProperty("target", out var target) && target.GetString() == "SecretMessageCreated") return json.RootElement.Clone(); } }
    private sealed record Identity(Guid Id, string Access, HttpClient Http) : IDisposable { public void Dispose() => Http.Dispose(); }
}
