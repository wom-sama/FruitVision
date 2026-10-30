using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text.Json;
using FruitVision.Api.Data;
using Microsoft.AspNetCore.Identity;
using Microsoft.Extensions.DependencyInjection;
using Xunit;

namespace FruitVision.Tests;

[Collection("Api")]
public sealed class LearningTests(ApiFixture fixture)
{
    [Theory]
    [InlineData("Consumer")]
    [InlineData("Producer")]
    [InlineData("Trader")]
    [InlineData("Admin")]
    public async Task Approved_roles_read_mango_learning_with_source_stages_and_plain_text(string role)
    {
        using var user = await Client(role);
        using var response = await user.GetAsync("/api/v1/learning/mango");
        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        var data = await response.Content.ReadFromJsonAsync<JsonElement>();
        Assert.Equal(1, data.GetProperty("schemaVersion").GetInt32());
        Assert.Equal("mango", data.GetProperty("productCode").GetString());
        Assert.Equal("mango", data.GetProperty("modelScope").GetProperty("acceptedSpecies").GetString());
        Assert.Equal("Xoài (dự đoán)", data.GetProperty("modelScope").GetProperty("objectLabel").GetString());
        Assert.Equal("source-two-stage", data.GetProperty("modelScope").GetProperty("stageBasis").GetString());
        var stages = data.GetProperty("modelScope").GetProperty("stages").EnumerateArray().ToArray();
        Assert.Equal(new[] { -1, 0, 1 }, stages.Select(s => s.GetProperty("code").GetInt32()).ToArray());
        Assert.Equal(new[] { "Chưa xác định", "Xanh / chưa chín", "Chín" }, stages.Select(s => s.GetProperty("label").GetString()).ToArray());
        var sections = data.GetProperty("sections").EnumerateArray().ToArray();
        Assert.True(sections.Length >= 3);
        Assert.All(sections, section => {
            Assert.False(string.IsNullOrWhiteSpace(section.GetProperty("title").GetString()));
            Assert.False(string.IsNullOrWhiteSpace(section.GetProperty("body").GetString()));
            Assert.DoesNotContain("<", section.GetProperty("body").GetString()!);
        });
        var limitations = string.Join(" ", data.GetProperty("limitations").EnumerateArray().Select(x => x.GetString()));
        Assert.Contains("an toàn thực phẩm", limitations);
        Assert.Contains("phi thương mại", limitations);
        Assert.Contains("bên trong", limitations);
        Assert.DoesNotContain("accuracy", data.GetRawText());
    }

    [Fact]
    public async Task Learning_requires_login_and_approval_without_granting_consumer_ai_access()
    {
        using var anonymous = fixture.CreateClient();
        using var denied = await anonymous.GetAsync("/api/v1/learning/mango");
        Assert.Equal(HttpStatusCode.Unauthorized, denied.StatusCode);
        using var pending = await Client("Consumer", approved: false);
        using var unapproved = await pending.GetAsync("/api/v1/learning/mango");
        Assert.Equal(HttpStatusCode.Forbidden, unapproved.StatusCode);
        using var consumer = await Client("Consumer");
        foreach (var route in new[] { "/api/v1/ai/guide", "/api/v1/ai/stats", "/api/v1/ai/capabilities", "/api/v1/ai/jobs" })
        {
            using var forbidden = await consumer.GetAsync(route);
            Assert.Equal(HttpStatusCode.Forbidden, forbidden.StatusCode);
        }
    }

    [Fact]
    public async Task Seller_guide_exposes_mango_scope_real_limits_and_abstention()
    {
        using var seller = await Client("Producer");
        using var response = await seller.GetAsync("/api/v1/ai/guide");
        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        var data = await response.Content.ReadFromJsonAsync<JsonElement>();
        Assert.Equal("mango", data.GetProperty("productCode").GetString());
        Assert.Equal("predicted-mango-only", data.GetProperty("scope").GetString());
        Assert.Equal("Không phát hiện xoài đạt ngưỡng", data.GetProperty("emptyResultMessage").GetString());
        Assert.Equal(24_000_000, data.GetProperty("maxImagePixels").GetInt32());
        Assert.Equal(3600, data.GetProperty("maxVideoFrames").GetInt32());
        Assert.Equal(12L * 1024 * 1024, data.GetProperty("maxImageBytes").GetInt64());
        Assert.Equal(80L * 1024 * 1024, data.GetProperty("maxVideoBytes").GetInt64());
        Assert.Equal(120, data.GetProperty("maxVideoSeconds").GetInt32());
        var limitations = string.Join(" ", data.GetProperty("limitations").EnumerateArray().Select(x => x.GetString()));
        Assert.Contains("hai nhãn", limitations);
        Assert.Contains("không chứng minh", limitations);
        Assert.Contains("khối lượng", limitations);
        Assert.Contains("hư hỏng", limitations);
    }

    private async Task<HttpClient> Client(string role, bool approved = true)
    {
        var email = $"learning.{Guid.NewGuid():N}@fruitvision.test";
        var user = new AppUser { Id = Guid.NewGuid(), UserName = email, Email = email, EmailConfirmed = true,
            DisplayName = "Learning fixture", Role = Enum.Parse<AccountRole>(role), IsActive = true,
            ApprovalStatus = approved ? ApprovalState.Approved : ApprovalState.Pending };
        using (var scope = fixture.Services.CreateScope())
            Assert.True((await scope.ServiceProvider.GetRequiredService<UserManager<AppUser>>().CreateAsync(user, fixture.Password)).Succeeded);
        var http = fixture.CreateClient();
        using var login = await http.PostAsJsonAsync("/api/v1/auth/login", new { email, password = fixture.Password });
        Assert.Equal(HttpStatusCode.OK, login.StatusCode);
        var session = await login.Content.ReadFromJsonAsync<JsonElement>();
        http.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", session.GetProperty("accessToken").GetString());
        return http;
    }
}
