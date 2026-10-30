using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Nodes;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.Extensions.Configuration;
using Xunit;

namespace FruitVision.Tests;

[Collection("Api")]
public sealed class MobileUpdateTests(ApiFixture fixture)
{
    private static readonly byte[] Apk = Enumerable.Range(0, 4096).Select(i => (byte)(i % 251)).ToArray();
    private const string Abi = "arm64-v8a";
    private const long Version = 7000;

    [Fact]
    public async Task Missing_manifest_disables_updates_without_exposing_private_configuration()
    {
        using var app = CreateApp();
        using var client = app.Factory.CreateClient();
        var response = await Check(client, 6002);
        AssertDisabled(response);
        Assert.DoesNotContain(app.Root, response.GetRawText(), StringComparison.OrdinalIgnoreCase);
        Assert.Equal(new[] { "apkSizeBytes", "available", "downloadPath", "latestVersionCode", "latestVersionName", "mandatory", "minimumSupportedVersionCode", "notes", "publishedAt", "schemaVersion", "sha256", "updateServiceEnabled" }, response.EnumerateObject().Select(p => p.Name).Order().ToArray());
    }

    [Fact]
    public async Task Optional_mandatory_current_and_absent_abi_decisions_match_the_published_manifest()
    {
        using var app = CreateApp();
        Publish(app.Root);
        using var client = app.Factory.CreateClient();
        var optional = await Check(client, 6002);
        Assert.True(optional.GetProperty("updateServiceEnabled").GetBoolean());
        Assert.True(optional.GetProperty("available").GetBoolean());
        Assert.False(optional.GetProperty("mandatory").GetBoolean());
        Assert.Equal(1, optional.GetProperty("schemaVersion").GetInt32());
        Assert.Equal(Version, optional.GetProperty("latestVersionCode").GetInt64());
        Assert.Equal("2.3.0", optional.GetProperty("latestVersionName").GetString());
        Assert.Equal(6002, optional.GetProperty("minimumSupportedVersionCode").GetInt64());
        Assert.Equal(Apk.Length, optional.GetProperty("apkSizeBytes").GetInt64());
        Assert.Equal(Hash(Apk), optional.GetProperty("sha256").GetString());
        Assert.Equal($"/api/v1/mobile/releases/{Version}/{Abi}.apk", optional.GetProperty("downloadPath").GetString());
        Assert.Equal("Bản cập nhật thử nghiệm.\nCần xác nhận cài đặt của Android.", optional.GetProperty("notes").GetString());
        Assert.Equal("2026-10-30T12:00:00+00:00", optional.GetProperty("publishedAt").GetString());
        var mandatory = await Check(client, 6001);
        Assert.True(mandatory.GetProperty("available").GetBoolean());
        Assert.True(mandatory.GetProperty("mandatory").GetBoolean());
        foreach (var current in new[] { Version, Version + 1 })
        {
            var latest = await Check(client, current);
            Assert.False(latest.GetProperty("available").GetBoolean());
            Assert.False(latest.GetProperty("mandatory").GetBoolean());
        }
        var absentAbi = await Check(client, 6001, "x86_64");
        Assert.True(absentAbi.GetProperty("updateServiceEnabled").GetBoolean());
        Assert.False(absentAbi.GetProperty("available").GetBoolean());
        Assert.True(absentAbi.GetProperty("mandatory").GetBoolean());
        Assert.Equal(JsonValueKind.Null, absentAbi.GetProperty("downloadPath").ValueKind);
        Assert.Equal(JsonValueKind.Null, absentAbi.GetProperty("sha256").ValueKind);
        Assert.Equal(JsonValueKind.Null, absentAbi.GetProperty("apkSizeBytes").ValueKind);
    }

    [Fact]
    public async Task Invalid_query_versions_and_unknown_abis_are_bad_requests()
    {
        using var app = CreateApp();
        using var client = app.Factory.CreateClient();
        foreach (var query in new[] { "versionCode=0&abi=arm64-v8a", "versionCode=-1&abi=arm64-v8a", "versionCode=9223372036854775808&abi=arm64-v8a", "versionCode=1.5&abi=arm64-v8a", "abi=arm64-v8a", "versionCode=1", "versionCode=1&abi=arm64", "versionCode=1&abi=ARM64-V8A" })
        {
            using var response = await client.GetAsync("/api/v1/mobile/update?" + query);
            Assert.Equal(HttpStatusCode.BadRequest, response.StatusCode);
        }
    }

    [Fact]
    public async Task Anonymous_download_streams_exact_registered_bytes_and_supports_ranges()
    {
        using var app = CreateApp();
        Publish(app.Root);
        File.WriteAllText(Path.Combine(app.Root, "private.txt"), "private operator data");
        using var client = app.Factory.CreateClient();
        var route = $"/api/v1/mobile/releases/{Version}/{Abi}.apk";
        using var response = await client.GetAsync(route);
        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        Assert.Equal("application/vnd.android.package-archive", response.Content.Headers.ContentType?.MediaType);
        Assert.Equal(Apk.Length, response.Content.Headers.ContentLength);
        Assert.Equal(Apk, await response.Content.ReadAsByteArrayAsync());
        using var request = new HttpRequestMessage(HttpMethod.Get, route);
        request.Headers.Range = new RangeHeaderValue(31, 70);
        using var partial = await client.SendAsync(request);
        Assert.Equal(HttpStatusCode.PartialContent, partial.StatusCode);
        Assert.Equal(31, partial.Content.Headers.ContentRange?.From);
        Assert.Equal(70, partial.Content.Headers.ContentRange?.To);
        Assert.Equal(Apk.Length, partial.Content.Headers.ContentRange?.Length);
        Assert.Equal(Apk[31..71], await partial.Content.ReadAsByteArrayAsync());
        foreach (var hidden in new[] { "/.local/mobile-releases/manifest.json", "/mobile-releases/private.txt", "/api/v1/mobile/releases/7000/private.txt", "/api/v1/mobile/releases/7000/x86_64.apk", "/api/v1/mobile/releases/7000/%2e%2e%2fprivate.apk", "/api/v1/mobile/releases/-1/arm64-v8a.apk" })
        {
            using var unknown = await client.GetAsync(hidden);
            Assert.Equal(HttpStatusCode.NotFound, unknown.StatusCode);
        }
    }

    [Fact]
    public async Task Version_snapshots_keep_old_registered_downloads_without_serving_unregistered_files()
    {
        using var app = CreateApp();
        Publish(app.Root);
        Publish(app.Root, Version + 1, Apk.Reverse().ToArray());
        var unregistered = Path.Combine(app.Root, (Version + 2).ToString());
        Directory.CreateDirectory(unregistered);
        File.WriteAllBytes(Path.Combine(unregistered, $"app-{Abi}-release.apk"), Apk);
        using var client = app.Factory.CreateClient();
        Assert.Equal(Version + 1, (await Check(client, 6002)).GetProperty("latestVersionCode").GetInt64());
        using var old = await client.GetAsync($"/api/v1/mobile/releases/{Version}/{Abi}.apk");
        Assert.Equal(HttpStatusCode.OK, old.StatusCode);
        Assert.Equal(Apk, await old.Content.ReadAsByteArrayAsync());
        using var unknown = await client.GetAsync($"/api/v1/mobile/releases/{Version + 2}/{Abi}.apk");
        Assert.Equal(HttpStatusCode.NotFound, unknown.StatusCode);
    }

    [Fact]
    public async Task Invalid_manifests_fail_closed_and_never_expose_paths_or_private_files()
    {
        using var app = CreateApp();
        using var client = app.Factory.CreateClient();
        Action<JsonObject>[] mutations =
        [
            m => m["schemaVersion"] = 2,
            m => m["packageName"] = "different.package",
            m => m["versionCode"] = 0,
            m => m["minimumSupportedVersionCode"] = Version + 1,
            m => m["versionName"] = "",
            m => m["notes"] = new string('x', 4001),
            m => m["artifacts"]![0]!["sha256"] = "not-a-sha256",
            m => m["artifacts"]![0]!["fileName"] = "../private.apk",
            m => m["artifacts"]![0]!["fileName"] = "C:\\private.apk",
            m => m["artifacts"]![0]!["sizeBytes"] = 80L * 1024 * 1024 + 1,
            m => m["artifacts"]![0]!["abi"] = "mips",
            m => m["artifacts"]!.AsArray().Add(m["artifacts"]![0]!.DeepClone())
        ];
        foreach (var mutate in mutations)
        {
            var manifest = Publish(app.Root);
            mutate(manifest);
            WriteManifest(app.Root, manifest);
            var response = await Check(client, 6002);
            AssertDisabled(response);
            Assert.DoesNotContain(app.Root, response.GetRawText(), StringComparison.OrdinalIgnoreCase);
            using var download = await client.GetAsync($"/api/v1/mobile/releases/{Version}/{Abi}.apk");
            Assert.Equal(HttpStatusCode.NotFound, download.StatusCode);
        }
    }

    [Fact]
    public async Task Missing_wrong_length_and_same_length_tampered_apks_are_never_advertised_or_downloaded()
    {
        using var app = CreateApp();
        using var client = app.Factory.CreateClient();
        foreach (var replacement in new byte[]?[] { null, Apk[..^1], Apk.Select(b => (byte)(b ^ 1)).ToArray() })
        {
            Publish(app.Root);
            var artifact = Path.Combine(app.Root, Version.ToString(), $"app-{Abi}-release.apk");
            if (replacement is null) File.Delete(artifact);
            else File.WriteAllBytes(artifact, replacement);
            AssertDisabled(await Check(client, 6002));
            using var response = await client.GetAsync($"/api/v1/mobile/releases/{Version}/{Abi}.apk");
            Assert.Equal(HttpStatusCode.NotFound, response.StatusCode);
        }
    }

    [Fact]
    public async Task Relative_root_and_malformed_or_oversized_manifest_disable_safely()
    {
        using (var app = CreateApp("relative-private-root"))
        using (var client = app.Factory.CreateClient())
            AssertDisabled(await Check(client, 6002));
        using var valid = CreateApp();
        using var http = valid.Factory.CreateClient();
        foreach (var text in new[] { "{broken-json", new string(' ', 65537) })
        {
            File.WriteAllText(Path.Combine(valid.Root, "manifest.json"), text);
            AssertDisabled(await Check(http, 6002));
        }
    }

    private UpdateApp CreateApp(string? configuredRoot = null)
    {
        var root = Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "../../../../../.local/mobile-update-tests", Guid.NewGuid().ToString("N")));
        Directory.CreateDirectory(root);
        var factory = fixture.WithWebHostBuilder(builder => builder.ConfigureAppConfiguration((_, config) => config.AddInMemoryCollection(new Dictionary<string, string?> { ["MobileUpdates:RootPath"] = configuredRoot ?? root })));
        return new(root, factory);
    }

    private static async Task<JsonElement> Check(HttpClient client, long current, string abi = Abi)
    {
        using var response = await client.GetAsync($"/api/v1/mobile/update?versionCode={current}&abi={abi}");
        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        return await response.Content.ReadFromJsonAsync<JsonElement>();
    }

    private static void AssertDisabled(JsonElement response)
    {
        Assert.Equal(1, response.GetProperty("schemaVersion").GetInt32());
        Assert.False(response.GetProperty("updateServiceEnabled").GetBoolean());
        Assert.False(response.GetProperty("available").GetBoolean());
        Assert.False(response.GetProperty("mandatory").GetBoolean());
        foreach (var field in new[] { "latestVersionName", "latestVersionCode", "minimumSupportedVersionCode", "apkSizeBytes", "sha256", "downloadPath", "notes", "publishedAt" })
            Assert.Equal(JsonValueKind.Null, response.GetProperty(field).ValueKind);
    }

    private static string Hash(byte[] bytes) => Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant();

    private static JsonObject Publish(string root, long version = Version, byte[]? bytes = null)
    {
        bytes ??= Apk;
        var dir = Path.Combine(root, version.ToString());
        Directory.CreateDirectory(dir);
        File.WriteAllBytes(Path.Combine(dir, $"app-{Abi}-release.apk"), bytes);
        var manifest = JsonSerializer.SerializeToNode(new { schemaVersion = 1, packageName = "vn.mangodemo.mango_offline", versionName = "2.3.0", versionCode = version, minimumSupportedVersionCode = 6002, notes = "Bản cập nhật thử nghiệm.\nCần xác nhận cài đặt của Android.", publishedAt = "2026-10-30T12:00:00+00:00", artifacts = new[] { new { abi = Abi, fileName = $"app-{Abi}-release.apk", sizeBytes = bytes.LongLength, sha256 = Hash(bytes) } } })!.AsObject();
        WriteManifest(root, manifest, version);
        return manifest;
    }

    private static void WriteManifest(string root, JsonObject manifest, long directoryVersion = Version)
    {
        var json = manifest.ToJsonString();
        File.WriteAllText(Path.Combine(root, "manifest.json"), json);
        File.WriteAllText(Path.Combine(root, directoryVersion.ToString(), "manifest.json"), json);
    }

    private sealed class UpdateApp(string root, WebApplicationFactory<Program> factory) : IDisposable
    {
        public string Root { get; } = root;
        public WebApplicationFactory<Program> Factory { get; } = factory;
        public void Dispose()
        {
            Factory.Dispose();
            if (Guid.TryParseExact(Path.GetFileName(Root), "N", out _) && Path.GetFileName(Path.GetDirectoryName(Root)) == "mobile-update-tests")
                Directory.Delete(Root, recursive: true);
        }
    }
}
