using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text.Json;
using FruitVision.Api.Ai;
using FruitVision.Api.Data;
using Microsoft.AspNetCore.Identity;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.EntityFrameworkCore;
using Xunit;

namespace FruitVision.Tests;

[Collection("Api")]
public sealed class AiInsightsTests(ApiFixture fixture)
{
    [Fact]
    public async Task Seller_statistics_aggregate_own_scalar_jobs_by_utc_day_and_window()
    {
        using var owner = await Client("Producer");
        using var other = await Client("Trader");
        using var route = await owner.Http.GetAsync("/api/v1/ai/stats?days=7");
        Assert.Equal(HttpStatusCode.OK, route.StatusCode);
        var today = new DateTimeOffset(DateTime.UtcNow.Date, TimeSpan.Zero);
        using var scope = fixture.Services.CreateScope();
        var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
        var active = Job(owner.UserId, today, "image", AiJobStatus.Queued, 0);
        db.AddRange(
            Job(owner.UserId, today, "image", AiJobStatus.Succeeded, 1),
            Job(owner.UserId, today.AddDays(-1), "video", AiJobStatus.Succeeded, 100),
            Job(owner.UserId, today, "video", AiJobStatus.Failed, 4),
            Job(owner.UserId, today.AddDays(-2), "image", AiJobStatus.Cancelled, 0), active,
            Job(owner.UserId, today.AddDays(-9), "image", AiJobStatus.Succeeded, 2),
            Job(other.UserId, today, "video", AiJobStatus.Succeeded, 999));
        await db.SaveChangesAsync();
        using var response = await owner.Http.GetAsync("/api/v1/ai/stats?days=7");
        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        var json = await response.Content.ReadFromJsonAsync<JsonElement>();
        Assert.Equal("own-jobs", json.GetProperty("scope").GetString());
        Assert.Equal("UTC", json.GetProperty("timeZone").GetString());
        var counts = json.GetProperty("counts");
        Assert.Equal(5, counts.GetProperty("total").GetInt32());
        Assert.Equal(2, counts.GetProperty("completed").GetInt32());
        Assert.Equal(1, counts.GetProperty("failed").GetInt32());
        Assert.Equal(1, counts.GetProperty("cancelled").GetInt32());
        Assert.Equal(1, counts.GetProperty("queued").GetInt32());
        Assert.Equal(0, counts.GetProperty("running").GetInt32());
        var media = json.GetProperty("media");
        Assert.Equal(3, media.GetProperty("imageJobs").GetInt32());
        Assert.Equal(2, media.GetProperty("videoJobs").GetInt32());
        Assert.Equal(105, media.GetProperty("framesProcessed").GetInt64());
        var days = json.GetProperty("jobsByDay").EnumerateArray().ToArray();
        Assert.Equal(7, days.Length);
        Assert.Equal(today.AddDays(-6).ToString("yyyy-MM-dd"), days[0].GetProperty("date").GetString());
        Assert.Equal(0, days[0].GetProperty("total").GetInt32());
        Assert.Equal(5, days.Sum(day => day.GetProperty("total").GetInt32()));
        Assert.NotEqual(JsonValueKind.Null, json.GetProperty("lastCompletedAt").ValueKind);
        Assert.DoesNotContain("privateSentinel", json.GetRawText());
        active.Status = AiJobStatus.Running;
        await db.SaveChangesAsync();
        var changed = await owner.Http.GetFromJsonAsync<JsonElement>("/api/v1/ai/stats?days=30");
        Assert.Equal(6, changed.GetProperty("counts").GetProperty("total").GetInt32());
        Assert.Equal(1, changed.GetProperty("counts").GetProperty("running").GetInt32());
        Assert.Equal(0, changed.GetProperty("counts").GetProperty("queued").GetInt32());
        Assert.Equal(30, changed.GetProperty("jobsByDay").GetArrayLength());
        active.Status = AiJobStatus.Cancelled;
        await db.SaveChangesAsync();
    }

    [Theory]
    [InlineData("Consumer")]
    [InlineData("Admin")]
    public async Task Non_sellers_cannot_read_stats_or_guide(string role)
    {
        using var user = await Client(role);
        foreach (var route in new[] { "/api/v1/ai/stats", "/api/v1/ai/guide" })
        {
            using var response = await user.Http.GetAsync(route);
            Assert.Equal(HttpStatusCode.Forbidden, response.StatusCode);
        }
    }

    [Fact]
    public async Task Empty_window_is_zero_filled_and_invalid_days_are_rejected()
    {
        using var user = await Client("Trader");
        using var response = await user.Http.GetAsync("/api/v1/ai/stats");
        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        var data = await response.Content.ReadFromJsonAsync<JsonElement>();
        Assert.Equal(7, data.GetProperty("days").GetInt32());
        Assert.Equal(0, data.GetProperty("counts").GetProperty("total").GetInt32());
        Assert.Equal(JsonValueKind.Null, data.GetProperty("lastCompletedAt").ValueKind);
        Assert.Equal(7, data.GetProperty("jobsByDay").GetArrayLength());
        foreach (var invalid in new[] { "0", "8", "365", "-1", "bad" })
        {
            using var bad = await user.Http.GetAsync("/api/v1/ai/stats?days=" + invalid);
            Assert.Equal(HttpStatusCode.BadRequest, bad.StatusCode);
        }
        using var longWindow = await user.Http.GetAsync("/api/v1/ai/stats?days=90");
        Assert.Equal(HttpStatusCode.OK, longWindow.StatusCode);
    }

    [Fact]
    public async Task Guide_explains_actual_server_limits_without_inventing_accuracy_or_stock()
    {
        using var user = await Client("Producer");
        using var response = await user.Http.GetAsync("/api/v1/ai/guide");
        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        var data = await response.Content.ReadFromJsonAsync<JsonElement>();
        Assert.Equal(1, data.GetProperty("schemaVersion").GetInt32());
        Assert.Equal("server", data.GetProperty("executionLocation").GetString());
        Assert.Equal(12L * 1024 * 1024, data.GetProperty("maxImageBytes").GetInt64());
        Assert.Equal(80L * 1024 * 1024, data.GetProperty("maxVideoBytes").GetInt64());
        Assert.Equal(120, data.GetProperty("maxVideoSeconds").GetInt32());
        Assert.Equal(180, data.GetProperty("maxProcessingSeconds").GetInt32());
        Assert.Equal(1, data.GetProperty("activeJobsPerUser").GetInt32());
        Assert.Equal(4, data.GetProperty("globalQueueCapacity").GetInt32());
        Assert.True(data.GetProperty("steps").GetArrayLength() >= 3);
        Assert.True(data.GetProperty("limitations").GetArrayLength() >= 3);
        using var anonymous = fixture.CreateClient();
        using var denied = await anonymous.GetAsync("/api/v1/ai/stats");
        Assert.Equal(HttpStatusCode.Unauthorized, denied.StatusCode);
    }

    private async Task<UserClient> Client(string role)
    {
        var email = $"insights.{Guid.NewGuid():N}@fruitvision.test";
        var user = new AppUser { Id = Guid.NewGuid(), UserName = email, Email = email, EmailConfirmed = true, DisplayName = "Insights fixture", Role = Enum.Parse<AccountRole>(role), ApprovalStatus = ApprovalState.Approved, IsActive = true };
        using (var scope = fixture.Services.CreateScope())
            Assert.True((await scope.ServiceProvider.GetRequiredService<UserManager<AppUser>>().CreateAsync(user, fixture.Password)).Succeeded);
        var http = fixture.CreateClient();
        using var response = await http.PostAsJsonAsync("/api/v1/auth/login", new { email, password = fixture.Password });
        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        var json = await response.Content.ReadFromJsonAsync<JsonElement>();
        http.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", json.GetProperty("accessToken").GetString());
        return new(user.Id, http);
    }

    private static AiJob Job(Guid userId, DateTimeOffset created, string media, AiJobStatus status, int frames) => new()
    {
        UserId = userId, ClientRequestId = Guid.NewGuid().ToString("N"), MediaType = media, ContentType = media == "image" ? "image/png" : "video/mp4", InputExtension = media == "image" ? ".png" : ".mp4",
        InputBytes = 4, InputSha256 = new string('a', 64), Status = status, FramesProcessed = frames, CreatedAt = created,
        CompletedAt = status is AiJobStatus.Succeeded or AiJobStatus.Failed or AiJobStatus.Cancelled ? created.AddSeconds(1) : null,
        ResultJson = status == AiJobStatus.Succeeded ? "{\"privateSentinel\":true}" : null
    };
    private sealed record UserClient(Guid UserId, HttpClient Http) : IDisposable { public void Dispose() => Http.Dispose(); }
}
