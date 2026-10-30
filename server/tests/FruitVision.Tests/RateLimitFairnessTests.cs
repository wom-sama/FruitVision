using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text.Json;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.Extensions.Configuration;
using Xunit;

namespace FruitVision.Tests;

[Collection("Api")]
public sealed class RateLimitFairnessTests(ApiFixture fixture)
{
    [Fact]
    public async Task Authenticated_users_have_independent_global_budgets_and_anonymous_keeps_ip_budget()
    {
        var producer = await Token("producer@fruitvision.test"); var trader = await Token("trader@fruitvision.test");
        using var app = Limited(2, 30); using var first = app.CreateClient(); using var second = app.CreateClient(); using var anonymous = app.CreateClient();
        first.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", producer);
        second.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", trader);
        for (var index = 0; index < 2; index++) { using var response = await first.GetAsync("/api/v1/auth/me"); Assert.Equal(HttpStatusCode.OK, response.StatusCode); }
        using var firstExhausted = await first.GetAsync("/api/v1/auth/me"); Assert.Equal(HttpStatusCode.TooManyRequests, firstExhausted.StatusCode);
        for (var index = 0; index < 2; index++) { using var response = await second.GetAsync("/api/v1/auth/me"); Assert.Equal(HttpStatusCode.OK, response.StatusCode); }
        using var secondExhausted = await second.GetAsync("/api/v1/auth/me"); Assert.Equal(HttpStatusCode.TooManyRequests, secondExhausted.StatusCode);
        for (var index = 0; index < 2; index++) { using var response = await anonymous.GetAsync("/health/live"); Assert.Equal(HttpStatusCode.OK, response.StatusCode); }
        using var anonymousExhausted = await anonymous.GetAsync("/health/live"); Assert.Equal(HttpStatusCode.TooManyRequests, anonymousExhausted.StatusCode);
        Assert.NotNull(anonymousExhausted.Headers.RetryAfter);
    }

    [Fact]
    public async Task Auth_endpoint_ip_budget_is_shared_even_between_authenticated_users()
    {
        var producer = await Token("producer@fruitvision.test"); var trader = await Token("trader@fruitvision.test");
        using var app = Limited(100, 1); using var first = app.CreateClient(); using var second = app.CreateClient();
        first.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", producer);
        second.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", trader);
        var request = new { email = $"absent-{Guid.NewGuid():N}@example.test", password = fixture.Password };
        using var accepted = await first.PostAsJsonAsync("/api/v1/auth/login", request); Assert.Equal(HttpStatusCode.Unauthorized, accepted.StatusCode);
        using var exhausted = await second.PostAsJsonAsync("/api/v1/auth/login", request); Assert.Equal(HttpStatusCode.TooManyRequests, exhausted.StatusCode);
        Assert.NotNull(exhausted.Headers.RetryAfter);
    }

    private WebApplicationFactory<Program> Limited(int global, int auth) => fixture.WithWebHostBuilder(builder => builder
        .ConfigureAppConfiguration((_, config) => config.AddInMemoryCollection(new Dictionary<string, string?>
        { ["Limits:RequestsPerMinute"] = global.ToString(), ["Limits:AuthPerMinute"] = auth.ToString() })));

    private async Task<string> Token(string email)
    {
        using var client = fixture.CreateClient(); using var response = await client.PostAsJsonAsync("/api/v1/auth/login", new { email, password = fixture.Password });
        Assert.Equal(HttpStatusCode.OK, response.StatusCode); return (await response.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("accessToken").GetString()!;
    }
}
