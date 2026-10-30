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
public class FoundationTests(ApiFixture fixture)
{
    [Fact]
    public async Task Registration_starts_pending_and_cannot_assign_admin()
    {
        using var client = fixture.CreateClient();
        var response = await client.PostAsJsonAsync("/api/v1/auth/register", new {
            displayName = "Người dùng kiểm thử", email = $"new-{Guid.NewGuid():N}@example.test",
            password = "A-long-test-password-52!", role = "Producer", region = "Đồng Tháp"
        });
        Assert.Equal(HttpStatusCode.Created, response.StatusCode);
        var data = await response.Content.ReadFromJsonAsync<JsonElement>();
        Assert.Equal("Pending", data.GetProperty("approvalStatus").GetString());
        var admin = await client.PostAsJsonAsync("/api/v1/auth/register", new {
            displayName = "Escalation", email = $"bad-{Guid.NewGuid():N}@example.test",
            password = "A-long-test-password-52!", role = "Admin", region = "Test"
        });
        Assert.Equal(HttpStatusCode.BadRequest, admin.StatusCode);
    }
}
