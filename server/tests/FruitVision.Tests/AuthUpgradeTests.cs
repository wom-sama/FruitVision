using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text.Json;
using Xunit;

namespace FruitVision.Tests;

[Collection("Api")]
public sealed class AuthUpgradeTests(ApiFixture fixture)
{
    [Fact]
    public async Task Public_registration_never_accepts_a_role_even_if_previously_public()
    {
        using var client = fixture.CreateClient();
        using var response = await client.PostAsJsonAsync("/api/v1/auth/register", new {
            displayName = "Role injection", email = $"inject-{Guid.NewGuid():N}@example.test",
            password = fixture.Password, role = "Producer", region = "Đồng Tháp"
        });
        Assert.Equal(HttpStatusCode.BadRequest, response.StatusCode);
    }

    [Theory]
    [InlineData("admin")]
    [InlineData("consumer")]
    public async Task Ai_is_for_approved_business_roles_only(string role)
    {
        using var client = fixture.CreateClient();
        using var login = await client.PostAsJsonAsync("/api/v1/auth/login", new { email = role + "@fruitvision.test", password = fixture.Password });
        var session = await login.Content.ReadFromJsonAsync<JsonElement>();
        client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", session.GetProperty("accessToken").GetString());
        using var response = await client.GetAsync("/api/v1/ai/capabilities");
        Assert.Equal(HttpStatusCode.Forbidden, response.StatusCode);
    }

    [Fact]
    public async Task Email_otp_capabilities_and_verification_exist_without_issuing_sessions_for_bad_codes()
    {
        using var client = fixture.CreateClient();
        using var methods = await client.GetAsync("/api/v1/auth/methods");
        Assert.Equal(HttpStatusCode.OK, methods.StatusCode);
        using var invalid = await client.PostAsJsonAsync("/api/v1/auth/otp/verify", new { challengeToken = new string('a', 43), code = "123456" });
        Assert.Equal(HttpStatusCode.Unauthorized, invalid.StatusCode);
        Assert.DoesNotContain("accessToken", await invalid.Content.ReadAsStringAsync());
    }
}
