using System.Net;
using System.Net.Http.Json;
using System.Text.Json;
using Microsoft.AspNetCore.Hosting;
using Microsoft.Extensions.Configuration;
using Xunit;

namespace FruitVision.Tests;

[Collection("Api")]
public class FoundationTests(ApiFixture fixture)
{
    [Theory]
    [InlineData("Admin")]
    [InlineData("Producer")]
    [InlineData("Trader")]
    [InlineData("Consumer")]
    public async Task Public_registration_cannot_assign_any_client_supplied_role(string role)
    {
        using var client = fixture.CreateClient();
        using var response = await client.PostAsJsonAsync("/api/v1/auth/register", new {
            displayName = "Người dùng kiểm thử", email = $"new-{Guid.NewGuid():N}@example.test",
            password = fixture.Password, role, countryCode = "VN", provinceCode = "79"
        });
        Assert.Equal(HttpStatusCode.BadRequest, response.StatusCode);
        var data = await response.Content.ReadFromJsonAsync<JsonElement>();
        Assert.False(data.TryGetProperty("accessToken", out _));
    }

    [Fact]
    public async Task Registration_without_email_transport_does_not_issue_a_session()
    {
        await using var app = fixture.WithWebHostBuilder(builder => builder.ConfigureAppConfiguration((_, config) =>
            config.AddInMemoryCollection(new Dictionary<string, string?> { ["EmailOtp:HashKey"] = "" })));
        using var client = app.CreateClient();
        using var response = await client.PostAsJsonAsync("/api/v1/auth/register", new {
            displayName = "Email unavailable", email = $"no-mail-{Guid.NewGuid():N}@example.test",
            password = fixture.Password, countryCode = "VN", provinceCode = "79"
        });
        Assert.Equal(HttpStatusCode.ServiceUnavailable, response.StatusCode);
        var data = await response.Content.ReadFromJsonAsync<JsonElement>();
        Assert.False(data.TryGetProperty("accessToken", out _));
        Assert.False(data.TryGetProperty("refreshToken", out _));
        using var me = await client.GetAsync("/api/v1/auth/me");
        Assert.Equal(HttpStatusCode.Unauthorized, me.StatusCode);
    }
}