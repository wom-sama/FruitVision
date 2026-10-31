using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text.Json;
using FruitVision.Api.Ai;
using FruitVision.Api.Data;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Xunit;

namespace FruitVision.Tests;

[Collection("Api")]
public sealed class LiveAiTests(ApiFixture fixture)
{
    private static readonly byte[] Jpeg = [255, 216, 255, 217];

    [Fact]
    public async Task Seller_live_start_is_session_bound_idempotent_and_reuses_one_engine()
    {
        var engine = new FakeEngine(); using var app = App(engine); using var producer = await Actor(app, "Producer");
        using var trader = await Actor(app, "Trader"); using var consumer = await Actor(app, "Consumer"); using var admin = await Actor(app, "Admin");
        using var anonymous = app.CreateClient();
        using var noLogin = await anonymous.PostAsJsonAsync("/api/v1/ai/live/sessions", new { }); Assert.Equal(HttpStatusCode.Unauthorized, noLogin.StatusCode);
        foreach (var denied in new[] { consumer.Http, admin.Http })
        { using var response = await denied.PostAsJsonAsync("/api/v1/ai/live/sessions", new { }); Assert.Equal(HttpStatusCode.Forbidden, response.StatusCode); }
        var first = await Start(producer.Http); var id = first.GetProperty("id").GetGuid();
        Assert.Equal(150, first.GetProperty("minFrameIntervalMs").GetInt32()); Assert.Equal(1048576, first.GetProperty("maxFrameBytes").GetInt32());
        Assert.Equal(960, first.GetProperty("maxEdge").GetInt32()); Assert.Equal(30, first.GetProperty("idleTimeoutSeconds").GetInt32());
        Assert.Equal(1, first.GetProperty("nextSequence").GetInt64());
        using var retry = await producer.Http.PostAsJsonAsync("/api/v1/ai/live/sessions", new { }); Assert.Equal(HttpStatusCode.OK, retry.StatusCode);
        Assert.Equal(id, (await retry.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("id").GetGuid());
        using var otherLogin = await Login(app, producer.Email);
        using var sameUserOtherSession = await otherLogin.PostAsJsonAsync("/api/v1/ai/live/sessions", new { }); Assert.Equal(HttpStatusCode.Conflict, sameUserOtherSession.StatusCode);
        var second = await Start(trader.Http); Assert.Equal(1, engine.Starts);
        using var foreign = await Frame(trader.Http, id, 1); Assert.Equal(HttpStatusCode.NotFound, foreign.StatusCode);
        using var sameUserForeignSession = await Frame(otherLogin, id, 1); Assert.Equal(HttpStatusCode.NotFound, sameUserForeignSession.StatusCode);
        using var third = await Actor(app, "Producer");
        using var capacity = await third.Http.PostAsJsonAsync("/api/v1/ai/live/sessions", new { }); Assert.Equal(HttpStatusCode.TooManyRequests, capacity.StatusCode);
        using var stop = await producer.Http.DeleteAsync($"/api/v1/ai/live/sessions/{id}"); Assert.Equal(HttpStatusCode.NoContent, stop.StatusCode);
        Assert.True(app.Services.GetRequiredService<LiveAiRuntime>().HasActiveSessions);
        using var stopLast = await trader.Http.DeleteAsync($"/api/v1/ai/live/sessions/{second.GetProperty("id").GetGuid()}"); Assert.Equal(HttpStatusCode.NoContent, stopLast.StatusCode);
        Assert.False(app.Services.GetRequiredService<LiveAiRuntime>().HasActiveSessions); Assert.Equal(1, engine.Stops);
    }

    [Fact]
    public async Task Frame_returns_mango_boxes_source_stages_visible_count_and_latency_without_creating_jobs()
    {
        var engine = new FakeEngine(); using var app = App(engine); using var seller = await Actor(app, "Producer");
        var id = (await Start(seller.Http)).GetProperty("id").GetGuid(); using var response = await Frame(seller.Http, id, 1);
        Assert.Equal(HttpStatusCode.OK, response.StatusCode); var result = await response.Content.ReadFromJsonAsync<JsonElement>();
        Assert.Equal("fruitvision-live-v1", result.GetProperty("schema").GetString()); Assert.Equal("predicted-mango-only", result.GetProperty("scope").GetString());
        Assert.Equal(LiveAiRuntime.ModelSha256, result.GetProperty("modelSha256").GetString()); Assert.Equal(1, result.GetProperty("sequence").GetInt64());
        Assert.Equal(640, result.GetProperty("imageWidth").GetInt32()); Assert.Equal(480, result.GetProperty("imageHeight").GetInt32());
        Assert.Equal(1, result.GetProperty("visibleCount").GetInt32()); Assert.Equal(1, result.GetProperty("stageCounts").GetProperty("Xanh / chưa chín").GetInt32());
        var obj = result.GetProperty("objects")[0]; Assert.Equal("Xoài (dự đoán)", obj.GetProperty("fruitLabel").GetString()); Assert.Equal(0, obj.GetProperty("stageCode").GetInt32());
        Assert.True(double.IsFinite(result.GetProperty("processingMs").GetDouble())); Assert.True(result.GetProperty("serverLatencyMs").GetDouble() >= 0);
        Assert.False(result.TryGetProperty("confirmedTrackCount", out _)); Assert.False(result.TryGetProperty("lineCrossingCount", out _));
        Assert.True(result.GetProperty("limitations").GetArrayLength() >= 3);
        using var scope = app.Services.CreateScope(); Assert.False(await scope.ServiceProvider.GetRequiredService<AppDbContext>().Set<AiJob>().AnyAsync(j => j.UserId == seller.Id));
    }

    [Fact]
    public async Task Stale_invalid_and_concurrent_frames_are_rejected_without_extra_inference()
    {
        var engine = new FakeEngine { Block = true }; var clock = new ManualClock(); using var app = App(engine, clock); using var seller = await Actor(app, "Trader");
        var id = (await Start(seller.Http)).GetProperty("id").GetGuid(); var first = Frame(seller.Http, id, 1);
        await engine.Entered.Task.WaitAsync(TimeSpan.FromSeconds(3));
        using var concurrent = await Frame(seller.Http, id, 2); Assert.Equal(HttpStatusCode.TooManyRequests, concurrent.StatusCode);
        engine.Release.TrySetResult(); using var completed = await first; Assert.Equal(HttpStatusCode.OK, completed.StatusCode);
        clock.Advance(TimeSpan.FromMilliseconds(200));
        using var old = await Frame(seller.Http, id, 1); Assert.Equal(HttpStatusCode.Conflict, old.StatusCode);
        using var type = await Frame(seller.Http, id, 2, contentType: "image/png"); Assert.Equal(HttpStatusCode.UnsupportedMediaType, type.StatusCode);
        using var huge = await Frame(seller.Http, id, 2, new byte[1048577]); Assert.Equal(HttpStatusCode.RequestEntityTooLarge, huge.StatusCode);
        using var malformed = await Frame(seller.Http, id, 2, [1, 2, 3]); Assert.Equal(HttpStatusCode.UnprocessableEntity, malformed.StatusCode);
        Assert.Equal(1, engine.Frames);
    }

    [Fact]
    public async Task One_global_pending_frame_is_discarded_when_aged_instead_of_being_inferred()
    {
        var engine = new FakeEngine { Block = true }; var clock = new ManualClock(); using var app = App(engine, clock);
        using var firstUser = await Actor(app, "Producer"); using var secondUser = await Actor(app, "Trader");
        var firstId = (await Start(firstUser.Http)).GetProperty("id").GetGuid(); var secondId = (await Start(secondUser.Http)).GetProperty("id").GetGuid();
        var first = Frame(firstUser.Http, firstId, 1); await engine.Entered.Task.WaitAsync(TimeSpan.FromSeconds(3));
        var second = Frame(secondUser.Http, secondId, 1); var runtime = app.Services.GetRequiredService<LiveAiRuntime>();
        using (var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(3)))
            while (runtime.PendingFrameCount != 1) await Task.Delay(10, timeout.Token);
        clock.Advance(TimeSpan.FromMilliseconds(1600)); engine.Release.TrySetResult();
        using var firstResult = await first; Assert.Equal(HttpStatusCode.OK, firstResult.StatusCode);
        using var stale = await second; Assert.Equal(HttpStatusCode.Conflict, stale.StatusCode); Assert.Equal(1, engine.Frames);
        engine.Block = false; using var fresh = await Frame(secondUser.Http, secondId, 2); Assert.Equal(HttpStatusCode.OK, fresh.StatusCode);
        Assert.Equal(2, engine.Frames); Assert.Equal(1, engine.Starts);
    }

    [Fact]
    public async Task Stop_and_idle_expiry_release_capacity_and_reject_old_session_frames()
    {
        var engine = new FakeEngine(); var clock = new ManualClock(); using var app = App(engine, clock); using var seller = await Actor(app, "Producer");
        var firstId = (await Start(seller.Http)).GetProperty("id").GetGuid(); clock.Advance(TimeSpan.FromSeconds(31));
        using var expired = await Frame(seller.Http, firstId, 1); Assert.Equal(HttpStatusCode.NotFound, expired.StatusCode);
        Assert.False(app.Services.GetRequiredService<LiveAiRuntime>().HasActiveSessions); Assert.Equal(1, engine.Stops);
        var newId = (await Start(seller.Http)).GetProperty("id").GetGuid(); Assert.NotEqual(firstId, newId); Assert.Equal(2, engine.Starts);
        using var stopped = await seller.Http.DeleteAsync($"/api/v1/ai/live/sessions/{newId}"); Assert.Equal(HttpStatusCode.NoContent, stopped.StatusCode);
        using var repeated = await seller.Http.DeleteAsync($"/api/v1/ai/live/sessions/{newId}"); Assert.Equal(HttpStatusCode.NoContent, repeated.StatusCode);
        using var old = await Frame(seller.Http, newId, 1); Assert.Equal(HttpStatusCode.NotFound, old.StatusCode); Assert.Equal(0, engine.Frames);
    }

    [Fact]
    public async Task Invalid_worker_numbers_fail_closed_and_remove_live_sessions()
    {
        var engine = new FakeEngine { Invalid = true }; using var app = App(engine); using var seller = await Actor(app, "Producer");
        var id = (await Start(seller.Http)).GetProperty("id").GetGuid(); using var response = await Frame(seller.Http, id, 1);
        Assert.Equal(HttpStatusCode.ServiceUnavailable, response.StatusCode); Assert.False(app.Services.GetRequiredService<LiveAiRuntime>().HasActiveSessions);
    }

    [Fact]
    public async Task Existing_file_jobs_prevent_live_start_before_any_worker_is_started()
    {
        var engine = new FakeEngine(); using var app = App(engine); using var seller = await Actor(app, "Producer");
        var job = new AiJob { UserId = seller.Id, ClientRequestId = Guid.NewGuid().ToString("N"), MediaType = "image", ContentType = "image/jpeg", InputExtension = ".jpg", InputBytes = 4, InputSha256 = new string('a', 64), Status = AiJobStatus.Queued };
        using var scope = app.Services.CreateScope(); var db = scope.ServiceProvider.GetRequiredService<AppDbContext>(); db.Add(job); await db.SaveChangesAsync();
        try { using var blocked = await seller.Http.PostAsJsonAsync("/api/v1/ai/live/sessions", new { }); Assert.Equal(HttpStatusCode.Conflict, blocked.StatusCode); Assert.Equal(0, engine.Starts); }
        finally { await db.Set<AiJob>().Where(j => j.Id == job.Id).ExecuteDeleteAsync(); }
    }

    [Fact]
    public async Task Live_session_blocks_file_upload_admission_until_stopped()
    {
        var engine = new FakeEngine(); using var app = App(engine, readyFileRuntime: true); using var seller = await Actor(app, "Producer");
        var id = (await Start(seller.Http)).GetProperty("id").GetGuid();
        async Task<HttpResponseMessage> Upload()
        {
            var request = new HttpRequestMessage(HttpMethod.Post, "/api/v1/ai/jobs?mediaType=image") { Content = new ByteArrayContent(Jpeg) };
            request.Content.Headers.ContentType = new MediaTypeHeaderValue("image/jpeg"); request.Headers.Add("X-Client-Request-Id", Guid.NewGuid().ToString("N"));
            return await seller.Http.SendAsync(request);
        }
        using var blocked = await Upload(); Assert.Equal(HttpStatusCode.TooManyRequests, blocked.StatusCode);
        using (var scope = app.Services.CreateScope()) Assert.False(await scope.ServiceProvider.GetRequiredService<AppDbContext>().Set<AiJob>().AnyAsync(j => j.UserId == seller.Id));
        using var stopped = await seller.Http.DeleteAsync($"/api/v1/ai/live/sessions/{id}"); Assert.Equal(HttpStatusCode.NoContent, stopped.StatusCode);
        using var accepted = await Upload(); Assert.Equal(HttpStatusCode.Accepted, accepted.StatusCode);
        var jobId = (await accepted.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("id").GetGuid();
        using var cancel = await seller.Http.PostAsync($"/api/v1/ai/jobs/{jobId}/cancel", null); Assert.Equal(HttpStatusCode.OK, cancel.StatusCode);
    }

    private WebApplicationFactory<Program> App(FakeEngine engine, ManualClock? clock = null, bool readyFileRuntime = false)
    {
        var settings = new Dictionary<string, string?> { ["AiLive:Enabled"] = "true" };
        if (readyFileRuntime)
        {
            var folder = Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "../../../../../.local/live-admission-tests", Guid.NewGuid().ToString("N")));
            foreach (var directory in new[] { "modules/onnxruntime/capi", "modules/numpy", "modules/PIL", "modules/cv2" }) Directory.CreateDirectory(Path.Combine(folder, directory));
            foreach (var file in new[] { "python.exe", "worker.py", "model.onnx", "modules/onnxruntime/__init__.py", "modules/onnxruntime/capi/onnxruntime_pybind11_state.test.pyd", "modules/numpy/__init__.py", "modules/PIL/__init__.py", "modules/cv2/__init__.py" })
                File.WriteAllText(Path.Combine(folder, file), "Admission fixture only; never executed.");
            settings["Ai:RunEnabled"] = "true"; settings["Ai:PythonPath"] = Path.Combine(folder, "python.exe"); settings["Ai:WorkerPath"] = Path.Combine(folder, "worker.py");
            settings["Ai:ModelPath"] = Path.Combine(folder, "model.onnx"); settings["Ai:PythonModulePath"] = Path.Combine(folder, "modules"); settings["Ai:PythonExtraModulePath"] = Path.Combine(folder, "modules"); settings["Ai:DataRoot"] = Path.Combine(folder, "data");
        }
        return fixture.WithWebHostBuilder(builder => builder
        .ConfigureAppConfiguration((_, config) => config.AddInMemoryCollection(settings))
        .ConfigureServices(services => {
            foreach (var descriptor in services.Where(s => s.ImplementationType == typeof(AiJobWorker)).ToArray()) services.Remove(descriptor);
            services.AddSingleton<ILiveAiEngine>(engine); services.AddSingleton<TimeProvider>(clock ?? new ManualClock());
        }));
    }
    private async Task<User> Actor(WebApplicationFactory<Program> app, string role)
    { var account = await TestAccounts.CreateAsync(app.Services, fixture.Password, role, displayName: "Live API fixture"); return new(account.Id, account.Email, await Login(app, account.Email)); }
    private async Task<HttpClient> Login(WebApplicationFactory<Program> app, string email)
    { var http = app.CreateClient(); using var response = await http.PostAsJsonAsync("/api/v1/auth/login", new { email, password = fixture.Password }); Assert.Equal(HttpStatusCode.OK, response.StatusCode); http.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", (await response.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("accessToken").GetString()); return http; }
    private static async Task<JsonElement> Start(HttpClient http)
    { using var response = await http.PostAsJsonAsync("/api/v1/ai/live/sessions", new { }); Assert.Equal(HttpStatusCode.Created, response.StatusCode); return await response.Content.ReadFromJsonAsync<JsonElement>(); }
    private static Task<HttpResponseMessage> Frame(HttpClient http, Guid id, long sequence, byte[]? bytes = null, string contentType = "image/jpeg")
    { var message = new HttpRequestMessage(HttpMethod.Post, $"/api/v1/ai/live/sessions/{id}/frames") { Content = new ByteArrayContent(bytes ?? Jpeg) }; message.Content.Headers.ContentType = new MediaTypeHeaderValue(contentType); message.Headers.Add("X-Frame-Sequence", sequence.ToString()); return http.SendAsync(message); }
    private sealed record User(Guid Id, string Email, HttpClient Http) : IDisposable { public void Dispose() => Http.Dispose(); }
    private sealed class ManualClock : TimeProvider
    {
        private DateTimeOffset now = DateTimeOffset.UtcNow;
        public override DateTimeOffset GetUtcNow() => now;
        public override long GetTimestamp() => now.UtcTicks;
        public override long TimestampFrequency => TimeSpan.TicksPerSecond;
        public void Advance(TimeSpan value) => now += value;
    }
    private sealed class FakeEngine : ILiveAiEngine
    {
        public int Starts, Stops, Frames;
        public bool Block, Invalid;
        public TaskCompletionSource Entered { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public TaskCompletionSource Release { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public bool IsReady => true;
        public Task StartAsync(CancellationToken ct) { Interlocked.Increment(ref Starts); return Task.CompletedTask; }
        public async Task<LiveAiFrameResult> InferAsync(byte[] jpeg, CancellationToken ct)
        {
            Interlocked.Increment(ref Frames); Entered.TrySetResult(); if (Block) await Release.Task.WaitAsync(ct);
            return new(640, 480, [new([.1, .2, .8, .9], Invalid ? double.NaN : .9, "Xoài (dự đoán)", 0, "Xanh / chưa chín")], .5);
        }
        public Task StopAsync(CancellationToken ct) { Interlocked.Increment(ref Stops); Release.TrySetResult(); return Task.CompletedTask; }
    }
}
