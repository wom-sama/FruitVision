using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text.Json;
using Xunit;

namespace FruitVision.Tests;

[Collection("Api")]
public sealed class SecurityFlowTests(ApiFixture fixture)
{
    [Fact]
    public async Task Business_registration_starts_pending_and_only_allows_public_reads_and_own_profile()
    {
        using var client = fixture.CreateClient();
        using var publicPosts = await client.GetAsync("/api/v1/posts");
        Assert.Equal(HttpStatusCode.OK, publicPosts.StatusCode);

        foreach (var role in new[] { "Producer", "Trader", "Consumer" })
        {
            var account = await RegisterAsync(client, role);
            var session = await LoginAsync(client, account.Email);
            Authorize(client, session);

            var me = await GetJsonAsync(client, "/api/v1/auth/me");
            Assert.Equal(account.Id, me.GetProperty("id").GetGuid());
            Assert.Equal(role, me.GetProperty("role").GetString());
            Assert.Equal("Pending", me.GetProperty("approvalStatus").GetString());

            using var publish = await client.PostAsJsonAsync("/api/v1/posts", PostBody());
            Assert.Equal(HttpStatusCode.Forbidden, publish.StatusCode);
            using var applications = await client.GetAsync("/api/v1/admin/applications");
            Assert.Equal(HttpStatusCode.Forbidden, applications.StatusCode);
            client.DefaultRequestHeaders.Authorization = null;
        }
    }

    [Fact]
    public async Task Registration_rejects_admin_and_privileged_mass_assignment()
    {
        using var client = fixture.CreateClient();
        using var adminRole = await client.PostAsJsonAsync("/api/v1/auth/register", RegistrationBody("Admin"));
        Assert.Equal(HttpStatusCode.BadRequest, adminRole.StatusCode);

        var forgedApproval = RegistrationBody("Producer");
        forgedApproval["approvalStatus"] = "Approved";
        using var approval = await client.PostAsJsonAsync("/api/v1/auth/register", forgedApproval);
        Assert.Equal(HttpStatusCode.BadRequest, approval.StatusCode);

        var forgedAdmin = RegistrationBody("Consumer");
        forgedAdmin["isAdmin"] = true;
        using var privilege = await client.PostAsJsonAsync("/api/v1/auth/register", forgedAdmin);
        Assert.Equal(HttpStatusCode.BadRequest, privilege.StatusCode);
    }

    [Fact]
    public async Task Only_admin_can_review_and_pending_is_not_a_review_decision()
    {
        using var client = fixture.CreateClient();
        using var admin = fixture.CreateClient();
        var applicant = await RegisterAsync(client, "Producer");
        Authorize(client, await LoginAsync(client, applicant.Email));

        using var selfApprove = await client.PostAsJsonAsync(
            $"/api/v1/admin/applications/{applicant.Id}/review",
            new { status = "Approved", reason = "Attempted self approval" });
        Assert.Equal(HttpStatusCode.Forbidden, selfApprove.StatusCode);
        Assert.Equal("Pending", (await GetJsonAsync(client, "/api/v1/auth/me"))
            .GetProperty("approvalStatus").GetString());

        Authorize(admin, await LoginAsync(admin, "admin@fruitvision.test"));
        using var invalidDecision = await admin.PostAsJsonAsync(
            $"/api/v1/admin/applications/{applicant.Id}/review",
            new { status = "Pending", reason = "Not a completed review" });
        Assert.Equal(HttpStatusCode.BadRequest, invalidDecision.StatusCode);

        await ApproveAsync(admin, applicant.Id);
        Assert.Equal("Approved", (await GetJsonAsync(client, "/api/v1/auth/me"))
            .GetProperty("approvalStatus").GetString());
    }

    [Fact]
    public async Task Approval_allows_producer_and_trader_posts_but_does_not_grant_consumer_publishing()
    {
        using var client = fixture.CreateClient();
        using var admin = fixture.CreateClient();
        Authorize(admin, await LoginAsync(admin, "admin@fruitvision.test"));

        foreach (var role in new[] { "Producer", "Trader", "Consumer" })
        {
            var account = await RegisterAsync(client, role);
            await ApproveAsync(admin, account.Id);
            Authorize(client, await LoginAsync(client, account.Email));

            using var publish = await client.PostAsJsonAsync("/api/v1/posts", PostBody());
            Assert.Equal(role == "Consumer" ? HttpStatusCode.Forbidden : HttpStatusCode.Created,
                publish.StatusCode);
            client.DefaultRequestHeaders.Authorization = null;
        }
    }

    [Fact]
    public async Task Invalid_credentials_do_not_issue_a_session()
    {
        using var client = fixture.CreateClient();
        var account = await RegisterAsync(client, "Consumer");

        using var wrongPassword = await client.PostAsJsonAsync("/api/v1/auth/login", new
        {
            email = account.Email,
            password = "A-different-invalid-password-53!"
        });
        Assert.Equal(HttpStatusCode.Unauthorized, wrongPassword.StatusCode);

        using var nonexistentUser = await client.PostAsJsonAsync("/api/v1/auth/login", new
        {
            email = $"missing-{Guid.NewGuid():N}@example.test",
            password = fixture.Password
        });
        Assert.Equal(HttpStatusCode.Unauthorized, nonexistentUser.StatusCode);
        using var me = await client.GetAsync("/api/v1/auth/me");
        Assert.Equal(HttpStatusCode.Unauthorized, me.StatusCode);
    }

    [Fact]
    public async Task Logout_revokes_the_current_access_and_refresh_tokens()
    {
        using var client = fixture.CreateClient();
        var account = await RegisterAsync(client, "Consumer");
        var session = await LoginAsync(client, account.Email);
        Authorize(client, session);
        using var logout = await client.PostAsync("/api/v1/auth/logout", null);
        Assert.Equal(HttpStatusCode.NoContent, logout.StatusCode);

        using var me = await client.GetAsync("/api/v1/auth/me");
        Assert.Equal(HttpStatusCode.Unauthorized, me.StatusCode);
        using var refresh = await client.PostAsJsonAsync("/api/v1/auth/refresh",
            new { refreshToken = session.RefreshToken });
        Assert.Equal(HttpStatusCode.Unauthorized, refresh.StatusCode);
    }

    [Fact]
    public async Task Refresh_rotates_tokens_and_replay_revokes_the_entire_session_family()
    {
        using var client = fixture.CreateClient();
        var account = await RegisterAsync(client, "Consumer");
        var original = await LoginAsync(client, account.Email);

        using var refresh = await client.PostAsJsonAsync("/api/v1/auth/refresh",
            new { refreshToken = original.RefreshToken });
        Assert.Equal(HttpStatusCode.OK, refresh.StatusCode);
        var rotated = await ReadSessionAsync(refresh);
        Assert.True(original.AccessToken != rotated.AccessToken, "Access tokens must rotate.");
        Assert.True(original.RefreshToken != rotated.RefreshToken, "Refresh tokens must rotate.");

        Authorize(client, original);
        using var staleAccess = await client.GetAsync("/api/v1/auth/me");
        Assert.Equal(HttpStatusCode.Unauthorized, staleAccess.StatusCode);
        Authorize(client, rotated);
        using var currentAccess = await client.GetAsync("/api/v1/auth/me");
        Assert.Equal(HttpStatusCode.OK, currentAccess.StatusCode);

        using var replay = await client.PostAsJsonAsync("/api/v1/auth/refresh",
            new { refreshToken = original.RefreshToken });
        Assert.Equal(HttpStatusCode.Unauthorized, replay.StatusCode);
        using var revokedAccess = await client.GetAsync("/api/v1/auth/me");
        Assert.Equal(HttpStatusCode.Unauthorized, revokedAccess.StatusCode);
        using var revokedRefresh = await client.PostAsJsonAsync("/api/v1/auth/refresh",
            new { refreshToken = rotated.RefreshToken });
        Assert.Equal(HttpStatusCode.Unauthorized, revokedRefresh.StatusCode);
    }

    [Fact]
    public async Task Locking_a_business_account_revokes_every_existing_session()
    {
        using var client = fixture.CreateClient();
        using var admin = fixture.CreateClient();
        var account = await RegisterAsync(client, "Producer");
        Authorize(admin, await LoginAsync(admin, "admin@fruitvision.test"));
        await ApproveAsync(admin, account.Id);
        var first = await LoginAsync(client, account.Email);
        var second = await LoginAsync(client, account.Email);

        using var locked = await admin.PostAsJsonAsync($"/api/v1/admin/users/{account.Id}/status",
            new { isActive = false, reason = "Integration test account lock" });
        Assert.Equal(HttpStatusCode.OK, locked.StatusCode);

        foreach (var session in new[] { first, second })
        {
            Authorize(client, session);
            using var access = await client.GetAsync("/api/v1/auth/me");
            Assert.Equal(HttpStatusCode.Unauthorized, access.StatusCode);
            using var refresh = await client.PostAsJsonAsync("/api/v1/auth/refresh",
                new { refreshToken = session.RefreshToken });
            Assert.Equal(HttpStatusCode.Unauthorized, refresh.StatusCode);
        }

        client.DefaultRequestHeaders.Authorization = null;
        using var login = await client.PostAsJsonAsync("/api/v1/auth/login",
            new { email = account.Email, password = fixture.Password });
        Assert.Equal(HttpStatusCode.Unauthorized, login.StatusCode);
    }

    [Fact]
    public async Task Conversation_messages_are_hidden_from_authenticated_nonmembers()
    {
        using var member = fixture.CreateClient();
        using var outsider = fixture.CreateClient();
        using var admin = fixture.CreateClient();
        Authorize(member, await LoginAsync(member, "producer@fruitvision.test"));
        var conversationId = await FirstConversationIdAsync(member);
        using var memberMessages = await member.GetAsync($"/api/v1/conversations/{conversationId}/messages");
        Assert.Equal(HttpStatusCode.OK, memberMessages.StatusCode);

        var account = await RegisterAsync(outsider, "Consumer");
        Authorize(admin, await LoginAsync(admin, "admin@fruitvision.test"));
        await ApproveAsync(admin, account.Id);
        Authorize(outsider, await LoginAsync(outsider, account.Email));

        var ownConversations = await GetJsonAsync(outsider, "/api/v1/conversations");
        Assert.Empty(Items(ownConversations));
        using var guessedId = await outsider.GetAsync($"/api/v1/conversations/{conversationId}/messages");
        Assert.Equal(HttpStatusCode.NotFound, guessedId.StatusCode);
    }

    [Fact]
    public async Task Message_retries_are_idempotent_and_html_is_returned_as_plain_json_text()
    {
        using var client = fixture.CreateClient();
        Authorize(client, await LoginAsync(client, "producer@fruitvision.test"));
        var conversationId = await FirstConversationIdAsync(client);
        var path = $"/api/v1/conversations/{conversationId}/messages";
        var messageKey = Guid.NewGuid().ToString("N");
        const string text = "<script>alert('untrusted')</script> Mango estimate only.";

        using var first = await client.PostAsJsonAsync(path, new { clientMessageId = messageKey, text });
        Assert.True(first.StatusCode is HttpStatusCode.OK or HttpStatusCode.Created,
            "The first message must be accepted.");
        Assert.Equal("application/json", first.Content.Headers.ContentType?.MediaType);
        var created = await first.Content.ReadFromJsonAsync<JsonElement>();
        Assert.Equal(text, created.GetProperty("text").GetString());
        var messageId = created.GetProperty("id").GetGuid();

        using var retry = await client.PostAsJsonAsync(path, new { clientMessageId = messageKey, text });
        Assert.True(retry.StatusCode is HttpStatusCode.OK or HttpStatusCode.Created,
            "Retrying identical content must return the existing message.");
        var existing = await retry.Content.ReadFromJsonAsync<JsonElement>();
        Assert.Equal(messageId, existing.GetProperty("id").GetGuid());
        Assert.Equal(text, existing.GetProperty("text").GetString());

        using var conflict = await client.PostAsJsonAsync(path,
            new { clientMessageId = messageKey, text = "Different content for the same key." });
        Assert.Equal(HttpStatusCode.Conflict, conflict.StatusCode);
    }

    [Fact]
    public async Task Json_contract_rejects_unknown_properties_wrong_casing_and_control_characters()
    {
        using var client = fixture.CreateClient();
        var wrongCase = RegistrationBody("Consumer");
        wrongCase["DisplayName"] = wrongCase["displayName"];
        wrongCase.Remove("displayName");
        using var casing = await client.PostAsJsonAsync("/api/v1/auth/register", wrongCase);
        Assert.Equal(HttpStatusCode.BadRequest, casing.StatusCode);

        var nulName = RegistrationBody("Producer");
        nulName["displayName"] = "Unsafe\0name";
        using var nul = await client.PostAsJsonAsync("/api/v1/auth/register", nulName);
        Assert.Equal(HttpStatusCode.BadRequest, nul.StatusCode);

        Authorize(client, await LoginAsync(client, "producer@fruitvision.test"));
        using var unknownPostField = await client.PostAsJsonAsync("/api/v1/posts", new
        {
            title = "Safe estimate title", body = "A safe estimate description.",
            productCode = "mango", estimatedQuantityKg = 20, authorId = Guid.NewGuid()
        });
        Assert.Equal(HttpStatusCode.BadRequest, unknownPostField.StatusCode);

        using var controlBody = await client.PostAsJsonAsync("/api/v1/posts", new
        {
            title = "Safe estimate title", body = "Description with a control \u0001 character.",
            productCode = "mango", estimatedQuantityKg = 20
        });
        Assert.Equal(HttpStatusCode.BadRequest, controlBody.StatusCode);

        var conversationId = await FirstConversationIdAsync(client);
        using var controlMessage = await client.PostAsJsonAsync(
            $"/api/v1/conversations/{conversationId}/messages",
            new { clientMessageId = Guid.NewGuid().ToString("N"), text = "Unsafe\0message" });
        Assert.Equal(HttpStatusCode.BadRequest, controlMessage.StatusCode);
    }

    [Fact]
    public async Task History_is_scoped_to_the_authenticated_user_even_with_another_user_id_in_query()
    {
        using var producer = fixture.CreateClient();
        using var trader = fixture.CreateClient();
        using var outsider = fixture.CreateClient();
        var producerSession = await LoginAsync(producer, "producer@fruitvision.test");
        Authorize(producer, producerSession);
        Authorize(trader, await LoginAsync(trader, "trader@fruitvision.test"));
        var producerHistory = Items(await GetJsonAsync(producer, "/api/v1/history"));
        var traderHistory = Items(await GetJsonAsync(trader, "/api/v1/history"));
        Assert.NotEmpty(producerHistory);
        Assert.NotEmpty(traderHistory);
        var producerIds = producerHistory.Select(item => item.GetProperty("id").GetGuid()).ToHashSet();
        Assert.All(traderHistory, item => Assert.DoesNotContain(item.GetProperty("id").GetGuid(), producerIds));

        var account = await RegisterAsync(outsider, "Consumer");
        Authorize(outsider, await LoginAsync(outsider, account.Email));
        var ownHistory = Items(await GetJsonAsync(outsider, "/api/v1/history"));
        var queriedHistory = Items(await GetJsonAsync(outsider,
            $"/api/v1/history?userId={producerSession.UserId}"));
        Assert.Equal(ownHistory.Select(item => item.GetProperty("id").GetGuid()),
            queriedHistory.Select(item => item.GetProperty("id").GetGuid()));
        Assert.All(queriedHistory, item => Assert.DoesNotContain(item.GetProperty("id").GetGuid(), producerIds));
    }

    private Dictionary<string, object> RegistrationBody(string role) => new()
    {
        ["displayName"] = "Integration Test User",
        ["email"] = $"security-{Guid.NewGuid():N}@example.test",
        ["password"] = fixture.Password,
        ["role"] = role,
        ["region"] = "Đồng Tháp"
    };

    private async Task<Account> RegisterAsync(HttpClient client, string role)
    {
        var request = RegistrationBody(role);
        using var response = await client.PostAsJsonAsync("/api/v1/auth/register", request);
        Assert.Equal(HttpStatusCode.Created, response.StatusCode);
        var profile = await response.Content.ReadFromJsonAsync<JsonElement>();
        Assert.Equal(role, profile.GetProperty("role").GetString());
        Assert.Equal("Pending", profile.GetProperty("approvalStatus").GetString());
        return new Account(profile.GetProperty("id").GetGuid(), (string)request["email"]);
    }

    private async Task<Session> LoginAsync(HttpClient client, string email)
    {
        using var response = await client.PostAsJsonAsync("/api/v1/auth/login",
            new { email, password = fixture.Password });
        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        return await ReadSessionAsync(response);
    }

    private static async Task<Session> ReadSessionAsync(HttpResponseMessage response)
    {
        var data = await response.Content.ReadFromJsonAsync<JsonElement>();
        var access = data.GetProperty("accessToken").GetString();
        var refresh = data.GetProperty("refreshToken").GetString();
        Assert.True(!string.IsNullOrWhiteSpace(access), "A successful session needs an access token.");
        Assert.True(!string.IsNullOrWhiteSpace(refresh), "A successful session needs a refresh token.");
        Assert.True(data.GetProperty("expiresIn").GetInt32() > 0, "Session expiry must be positive.");
        return new Session(access!, refresh!, data.GetProperty("user").GetProperty("id").GetGuid());
    }

    private static void Authorize(HttpClient client, Session session) =>
        client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", session.AccessToken);

    private static async Task ApproveAsync(HttpClient admin, Guid applicantId)
    {
        using var response = await admin.PostAsJsonAsync($"/api/v1/admin/applications/{applicantId}/review",
            new { status = "Approved", reason = "Reviewed for an isolated integration test" });
        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
    }

    private static object PostBody() => new
    {
        title = "Mango estimate for integration test",
        body = "Estimated mango quantity for a future survey, without a stock commitment.",
        productCode = "mango",
        estimatedQuantityKg = 20
    };

    private static async Task<JsonElement> GetJsonAsync(HttpClient client, string path)
    {
        using var response = await client.GetAsync(path);
        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        return await response.Content.ReadFromJsonAsync<JsonElement>();
    }

    private static JsonElement[] Items(JsonElement envelope) => envelope.GetProperty("items").EnumerateArray().ToArray();

    private static async Task<Guid> FirstConversationIdAsync(HttpClient client)
    {
        var conversations = Items(await GetJsonAsync(client, "/api/v1/conversations"));
        Assert.NotEmpty(conversations);
        return conversations[0].GetProperty("id").GetGuid();
    }

    private sealed record Account(Guid Id, string Email);
    private sealed record Session(string AccessToken, string RefreshToken, Guid UserId);
}
