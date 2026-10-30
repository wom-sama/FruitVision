using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text.Json;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using FruitVision.Api.Ai;
using Xunit;

namespace FruitVision.Tests;

[Collection("Api")]
public sealed class AiJobTests(ApiFixture fixture)
{
    private static readonly byte[] Png = Convert.FromBase64String("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=");

    private WebApplicationFactory<Program> CreateApp(bool runEnabled = true)
    {
        var root = Path.Combine(Path.GetTempPath(), "fruitvision-ai-tests", Guid.NewGuid().ToString("N"));
        foreach (var package in new[] { "onnxruntime/capi", "numpy", "PIL", "cv2" })
            Directory.CreateDirectory(Path.Combine(root, "modules", package));
        foreach (var file in new[] { "python.exe", "worker.py", "model.onnx", "modules/onnxruntime/__init__.py",
            "modules/onnxruntime/capi/onnxruntime_pybind11_state.test.pyd", "modules/numpy/__init__.py", "modules/PIL/__init__.py", "modules/cv2/__init__.py" })
            File.WriteAllText(Path.Combine(root, file), "test fixture; never executed");
        return fixture.WithWebHostBuilder(builder => builder
        .ConfigureServices(services =>
        {
            // Exercise real HTTP + PostgreSQL admission without launching a decoder process.
            foreach (var descriptor in services.Where(item => item.ImplementationType == typeof(AiJobWorker)).ToArray())
                services.Remove(descriptor);
        })
        .ConfigureAppConfiguration((_, config) => config.AddInMemoryCollection(new Dictionary<string, string?>
        {
            ["Ai:RunEnabled"] = runEnabled.ToString(), ["Ai:DataRoot"] = Path.Combine(root, "data"),
            ["Ai:PythonPath"] = Path.Combine(root, "python.exe"), ["Ai:WorkerPath"] = Path.Combine(root, "worker.py"),
            ["Ai:ModelPath"] = Path.Combine(root, "model.onnx"), ["Ai:PythonModulePath"] = Path.Combine(root, "modules"),
            ["Ai:PythonExtraModulePath"] = Path.Combine(root, "modules")
        })));
    }

    [Fact]
    public async Task Ai_requires_an_authenticated_approved_account()
    {
        using var app = CreateApp();
        using var client = app.CreateClient();
        using var anonymous = await client.GetAsync("/api/v1/ai/jobs");
        Assert.Equal(HttpStatusCode.Unauthorized, anonymous.StatusCode);
        await LoginNewAsync(client, app, approve: false);
        using var pending = await UploadAsync(client);
        Assert.Equal(HttpStatusCode.Forbidden, pending.StatusCode);
        using var capabilities = await client.GetAsync("/api/v1/ai/capabilities");
        Assert.Equal(HttpStatusCode.Forbidden, capabilities.StatusCode);
    }

    [Theory]
    [InlineData("Producer")]
    [InlineData("Trader")]
    [InlineData("Consumer")]
    [InlineData("Admin")]
    public async Task Every_approved_role_can_queue_and_cancel_a_private_image(string role)
    {
        using var app = CreateApp();
        using var client = app.CreateClient();
        if (role == "Admin") await LoginAsync(client, "admin@fruitvision.test");
        else await LoginNewAsync(client, app, role: role);
        using var created = await UploadAsync(client);
        Assert.Equal(HttpStatusCode.Accepted, created.StatusCode);
        var job = await created.Content.ReadFromJsonAsync<JsonElement>();
        var id = job.GetProperty("id").GetGuid();
        try
        {
            Assert.Equal("Queued", job.GetProperty("status").GetString());
            Assert.Equal("image", job.GetProperty("mediaType").GetString());
            Assert.Equal(0, job.GetProperty("progress").GetInt32());
            Assert.Equal(1, job.GetProperty("revision").GetInt64());
            Assert.False(job.GetProperty("previewAvailable").GetBoolean());
            Assert.Equal(JsonValueKind.Null, job.GetProperty("result").ValueKind);
            Assert.False(job.TryGetProperty("inputPath", out _));
            Assert.False(job.TryGetProperty("userId", out _));
            using var capabilities = await client.GetAsync("/api/v1/ai/capabilities");
            Assert.Equal(HttpStatusCode.OK, capabilities.StatusCode);
            var config = await capabilities.Content.ReadFromJsonAsync<JsonElement>();
            Assert.True(config.GetProperty("aiReady").GetBoolean());
            Assert.Equal(12 * 1024 * 1024, config.GetProperty("maxImageBytes").GetInt64());
        }
        finally { await CancelAsync(client, id); }
    }

    [Fact]
    public async Task Disabled_runtime_rejects_upload_without_claiming_a_queued_job()
    {
        using var app = CreateApp(runEnabled: false);
        using var client = app.CreateClient();
        await LoginNewAsync(client, app);
        using var rejected = await UploadAsync(client);
        Assert.Equal(HttpStatusCode.ServiceUnavailable, rejected.StatusCode);
        var list = await client.GetFromJsonAsync<JsonElement>("/api/v1/ai/jobs");
        Assert.Empty(list.GetProperty("items").EnumerateArray());
    }

    [Fact]
    public async Task Other_users_cannot_read_cancel_or_download_a_job()
    {
        using var app = CreateApp();
        using var owner = app.CreateClient();
        using var outsider = app.CreateClient();
        await LoginNewAsync(owner, app);
        await LoginNewAsync(outsider, app);
        using var created = await UploadAsync(owner);
        Assert.Equal(HttpStatusCode.Accepted, created.StatusCode);
        var id = (await created.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("id").GetGuid();
        try
        {
            foreach (var suffix in new[] { "", "/preview" })
            {
                using var hidden = await outsider.GetAsync($"/api/v1/ai/jobs/{id}{suffix}");
                Assert.Equal(HttpStatusCode.NotFound, hidden.StatusCode);
            }
            using var cancel = await outsider.PostAsync($"/api/v1/ai/jobs/{id}/cancel", null);
            Assert.Equal(HttpStatusCode.NotFound, cancel.StatusCode);
            var list = await outsider.GetFromJsonAsync<JsonElement>("/api/v1/ai/jobs");
            Assert.DoesNotContain(list.GetProperty("items").EnumerateArray(), item => item.GetProperty("id").GetGuid() == id);
            using var prematurePreview = await owner.GetAsync($"/api/v1/ai/jobs/{id}/preview");
            Assert.Equal(HttpStatusCode.NotFound, prematurePreview.StatusCode);
        }
        finally { await CancelAsync(owner, id); }
    }

    [Fact]
    public async Task Request_key_retries_reuse_job_and_active_quota_is_released_by_cancel()
    {
        using var app = CreateApp();
        using var client = app.CreateClient();
        await LoginNewAsync(client, app);
        var key = Guid.NewGuid().ToString("N");
        using var created = await UploadAsync(client, key: key);
        Assert.Equal(HttpStatusCode.Accepted, created.StatusCode);
        var id = (await created.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("id").GetGuid();
        try
        {
            using var retry = await UploadAsync(client, key: key);
            Assert.Equal(HttpStatusCode.OK, retry.StatusCode);
            Assert.Equal(id, (await retry.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("id").GetGuid());
            // Same-length bytes retaining the PNG signature must not inherit the original result.
            var differentPng = Png.ToArray();
            differentPng[44] ^= 1;
            using var changedBytes = await UploadAsync(client, key: key, bytes: differentPng);
            Assert.Equal(HttpStatusCode.Conflict, changedBytes.StatusCode);
            using var changedMime = await UploadAsync(client, key: key, contentType: "image/jpeg", bytes: []);
            Assert.Equal(HttpStatusCode.Conflict, changedMime.StatusCode);
            using var oversizedRetry = await UploadAsync(client, key: key, bytes: new byte[12 * 1024 * 1024 + 1]);
            Assert.Equal(HttpStatusCode.RequestEntityTooLarge, oversizedRetry.StatusCode);
            using var blocked = await UploadAsync(client);
            Assert.Equal(HttpStatusCode.TooManyRequests, blocked.StatusCode);
            Assert.NotNull(blocked.Headers.RetryAfter);
        }
        finally { await CancelAsync(client, id); }
        using var terminalRetry = await UploadAsync(client, key: key);
        Assert.Equal(HttpStatusCode.OK, terminalRetry.StatusCode);
        var original = await terminalRetry.Content.ReadFromJsonAsync<JsonElement>();
        Assert.Equal(id, original.GetProperty("id").GetGuid());
        Assert.Equal("Cancelled", original.GetProperty("status").GetString());
        using var next = await UploadAsync(client);
        Assert.Equal(HttpStatusCode.Accepted, next.StatusCode);
        await CancelAsync(client, (await next.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("id").GetGuid());
        var history = await client.GetFromJsonAsync<JsonElement>("/api/v1/history");
        Assert.Contains(history.GetProperty("items").EnumerateArray(), item => item.GetProperty("kind").GetString() == "AiJobCancelled");
    }

    [Fact]
    public async Task Global_admission_limits_all_users_to_four_active_jobs()
    {
        using var app = CreateApp();
        var queued = new List<(HttpClient Client, Guid Id)>();
        var clients = new List<HttpClient>();
        try
        {
            for (var index = 0; index < 5; index++)
            {
                var client = app.CreateClient();
                clients.Add(client);
                await LoginNewAsync(client, app);
                using var response = await UploadAsync(client);
                if (index == 4)
                {
                    Assert.Equal(HttpStatusCode.TooManyRequests, response.StatusCode);
                    Assert.NotNull(response.Headers.RetryAfter);
                    continue;
                }
                Assert.Equal(HttpStatusCode.Accepted, response.StatusCode);
                queued.Add((client, (await response.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("id").GetGuid()));
            }
        }
        finally
        {
            foreach (var item in queued) await CancelAsync(item.Client, item.Id);
            foreach (var client in clients) client.Dispose();
        }
    }

    [Fact]
    public async Task Cancel_deletes_original_input_and_keeps_terminal_metadata_with_higher_revision()
    {
        using var app = CreateApp();
        using var client = app.CreateClient();
        await LoginNewAsync(client, app);
        using var response = await UploadAsync(client);
        Assert.Equal(HttpStatusCode.Accepted, response.StatusCode);
        var id = (await response.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("id").GetGuid();
        var storage = app.Services.GetRequiredService<AiStorage>();
        var inputPath = storage.InputFor(new AiJob { Id = id, InputExtension = ".png" });
        Assert.True(File.Exists(inputPath));
        await CancelAsync(client, id);
        Assert.False(File.Exists(inputPath));
        var job = await client.GetFromJsonAsync<JsonElement>($"/api/v1/ai/jobs/{id}");
        Assert.Equal("Cancelled", job.GetProperty("status").GetString());
        Assert.True(job.GetProperty("revision").GetInt64() > 1);
        Assert.NotEqual(JsonValueKind.Null, job.GetProperty("completedAt").ValueKind);
        var cancelledRevision = job.GetProperty("revision").GetInt64();
        // Simulates completion arriving after the worker has observed an API cancellation.
        await app.Services.GetRequiredService<AiJobEvents>().FinishAsync(id, AiJobStatus.Succeeded,
            result: "{}", preview: true);
        var afterLateCompletion = await client.GetFromJsonAsync<JsonElement>($"/api/v1/ai/jobs/{id}");
        Assert.Equal("Cancelled", afterLateCompletion.GetProperty("status").GetString());
        Assert.Equal(cancelledRevision, afterLateCompletion.GetProperty("revision").GetInt64());
        Assert.False(afterLateCompletion.GetProperty("previewAvailable").GetBoolean());
        Assert.Equal(JsonValueKind.Null, afterLateCompletion.GetProperty("result").ValueKind);
    }

    [Fact]
    public async Task Invalid_magic_content_type_request_key_and_oversize_are_rejected()
    {
        using var app = CreateApp();
        using var client = app.CreateClient();
        await LoginNewAsync(client, app);
        using var magic = await UploadAsync(client, bytes: "not an image at all"u8.ToArray());
        Assert.Equal(HttpStatusCode.BadRequest, magic.StatusCode);
        using var mime = await UploadAsync(client, contentType: "application/json");
        Assert.Equal(HttpStatusCode.UnsupportedMediaType, mime.StatusCode);
        using var key = await UploadAsync(client, key: "../bad");
        Assert.Equal(HttpStatusCode.BadRequest, key.StatusCode);
        using var media = await UploadAsync(client, mediaType: "https://untrusted.example/input");
        Assert.Equal(HttpStatusCode.BadRequest, media.StatusCode);
        using var oversized = await UploadAsync(client, bytes: new byte[12 * 1024 * 1024 + 1]);
        Assert.Equal(HttpStatusCode.RequestEntityTooLarge, oversized.StatusCode);
        var list = await client.GetFromJsonAsync<JsonElement>("/api/v1/ai/jobs");
        Assert.Empty(list.GetProperty("items").EnumerateArray());
    }

    private static async Task<HttpResponseMessage> UploadAsync(HttpClient client, byte[]? bytes = null,
        string? key = null, string contentType = "image/png", string mediaType = "image")
    {
        using var request = new HttpRequestMessage(HttpMethod.Post, "/api/v1/ai/jobs?mediaType=" + Uri.EscapeDataString(mediaType));
        request.Headers.Add("X-Client-Request-Id", key ?? Guid.NewGuid().ToString("N"));
        request.Content = new ByteArrayContent(bytes ?? Png);
        request.Content.Headers.ContentType = new MediaTypeHeaderValue(contentType);
        return await client.SendAsync(request);
    }

    private async Task LoginNewAsync(HttpClient client, WebApplicationFactory<Program> app,
        bool approve = true, string role = "Producer")
    {
        var email = $"ai-{Guid.NewGuid():N}@example.test";
        using var registered = await client.PostAsJsonAsync("/api/v1/auth/register", new
        { displayName = "AI test account", email, password = fixture.Password, role, region = "Đồng Tháp" });
        Assert.Equal(HttpStatusCode.Created, registered.StatusCode);
        var id = (await registered.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("id").GetGuid();
        if (approve)
        {
            using var admin = app.CreateClient();
            await LoginAsync(admin, "admin@fruitvision.test");
            using var reviewed = await admin.PostAsJsonAsync($"/api/v1/admin/applications/{id}/review",
                new { status = "Approved", reason = "AI integration test" });
            Assert.Equal(HttpStatusCode.OK, reviewed.StatusCode);
        }
        await LoginAsync(client, email);
    }

    private async Task LoginAsync(HttpClient client, string email)
    {
        using var response = await client.PostAsJsonAsync("/api/v1/auth/login", new { email, password = fixture.Password });
        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        var data = await response.Content.ReadFromJsonAsync<JsonElement>();
        client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", data.GetProperty("accessToken").GetString());
    }

    private static async Task CancelAsync(HttpClient client, Guid id)
    {
        using var response = await client.PostAsync($"/api/v1/ai/jobs/{id}/cancel", null);
        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        Assert.Equal("Cancelled", (await response.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("status").GetString());
    }
}
