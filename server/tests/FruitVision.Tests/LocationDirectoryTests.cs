using System.Net;
using System.Text;
using System.Text.Json;
using FruitVision.Api.Infrastructure;
using Xunit;

namespace FruitVision.Tests;

public class LocationDirectoryTests
{
    private sealed class Clock : TimeProvider
    {
        public DateTimeOffset Now = new(2026, 10, 30, 0, 0, 0, TimeSpan.Zero);
        public override DateTimeOffset GetUtcNow() => Now;
    }
    private sealed class Provider : HttpMessageHandler, IHttpClientFactory
    {
        public int Calls;
        public bool Fail, Deprecated = true, TooLarge, Malformed, Redirect;
        public int VnCount = 34;
        public TaskCompletionSource<bool>? Gate;
        public readonly List<string> Uris = [];
        public readonly Clock Clock = new();
        public LocationDirectory Directory => new(this, Clock);
        public HttpClient CreateClient(string name) => new(this, disposeHandler: false);
        private static readonly string[] Codes = Enumerable.Range(0, 110)
            .Select(i => $"{(char)('A' + i / 26)}{(char)('A' + i % 26)}")
            .Concat(["VN", "US", "GB"]).Distinct().ToArray();
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token)
        {
            Interlocked.Increment(ref Calls);
            lock (Uris) Uris.Add(request.RequestUri!.AbsoluteUri);
            if (Gate is not null) await Gate.Task.WaitAsync(token);
            if (Fail) return new(HttpStatusCode.ServiceUnavailable);
            if (Redirect) return new(HttpStatusCode.Found) { Headers = { Location = new Uri("http://127.0.0.1/private") } };
            if (Malformed) return new(HttpStatusCode.OK) { Content = new StringContent("{\"unexpected\":true}", Encoding.UTF8, "application/json") };
            if (TooLarge) return new(HttpStatusCode.OK) { Content = new StringContent(new string('x', 2 * 1024 * 1024 + 1)) };
            object value;
            var host = request.RequestUri!.Host;
            if (host == "restcountries.com")
                value = Deprecated ? new { success = false, data = (object?)null } :
                    Codes.Select(code => new { cca2 = code, name = new { common = "Country " + code } }).ToArray();
            else if (host == "raw.githubusercontent.com")
                value = new { main = new { vi = new { localeDisplayNames = new { territories = Codes.ToDictionary(c => c,
                    c => c == "VN" ? "Việt Nam" : c == "US" ? "Hoa Kỳ" : "Quốc gia " + c) } } } };
            else if (host == "provinces.open-api.vn")
                value = Enumerable.Range(1, VnCount).Select(i => new { code = i, name = $"Tỉnh {i:D2}" }).ToArray();
            else if (host == "countriesnow.space")
                value = new { error = false, data = Codes.Select(code => new { iso2 = code, name = "Country " + code,
                    states = code == "US" ? new[] { new { name = "California", state_code = "CA" }, new { name = "Reference State", state_code = "" } } :
                        code == "VN" ? new[] { new { name = "LEGACY MUST NOT BE USED", state_code = "old" } } :
                        Array.Empty<object>() }).ToArray() };
            else throw new InvalidOperationException("Unexpected provider");
            return new(HttpStatusCode.OK) { Content = new StringContent(JsonSerializer.Serialize(value), Encoding.UTF8, "application/json") };
        }
    }

    [Fact]
    public async Task Deprecated_restcountries_falls_back_to_verified_source_and_vietnamese_labels()
    {
        using var p = new Provider(); var result = await p.Directory.GetCountriesAsync();
        Assert.Contains(result.Items, x => x.Code == "VN" && x.Name == "Việt Nam");
        Assert.Contains("CountriesNow", result.Source); Assert.Contains("CLDR", result.Source);
        Assert.False(result.Stale); Assert.Equal(p.Clock.Now, result.AsOf);
    }
    [Fact]
    public async Task Healthy_restcountries_remains_primary_without_requesting_global_state_fallback()
    {
        using var p = new Provider { Deprecated = false }; var result = await p.Directory.GetCountriesAsync();
        Assert.Contains("REST Countries", result.Source); Assert.DoesNotContain(p.Uris, u => u.Contains("countriesnow.space"));
    }
    [Fact]
    public async Task Vietnam_uses_only_current_v2_34_and_trusted_labels()
    {
        using var p = new Provider(); var directory = p.Directory;
        var result = await directory.GetProvincesAsync("vn");
        Assert.Equal(34, result.Items.Count); Assert.Equal("VN", result.CountryCode);
        Assert.Contains(p.Uris, u => u == "https://provinces.open-api.vn/api/v2/");
        Assert.DoesNotContain(result.Items, x => x.Name.Contains("LEGACY"));
        var valid = await directory.ValidateAsync("VN", "01");
        Assert.Equal("Tỉnh 01, Việt Nam", valid.Region); Assert.Equal("01", valid.ProvinceCode);
    }
    [Fact]
    public async Task A_63_province_payload_is_unavailable_and_never_uses_legacy_global_states()
    {
        using var p = new Provider { VnCount = 63 };
        await Assert.ThrowsAsync<LocationDirectoryUnavailableException>(() => p.Directory.GetProvincesAsync("VN"));
    }
    [Fact]
    public async Task Foreign_provider_codes_are_preserved_and_missing_codes_are_labelled_internal()
    {
        using var p = new Provider(); var d = p.Directory; var provinces = await d.GetProvincesAsync("US");
        Assert.Contains(provinces.Items, x => x.Code == "CA" && x.CodeKind == "providerStateCode");
        var reference = Assert.Single(provinces.Items, x => x.CodeKind == "internalReference");
        Assert.StartsWith("ref:US:", reference.Code);
        await Assert.ThrowsAsync<LocationSelectionException>(() => d.ValidateAsync("VN", reference.Code));
        await Assert.ThrowsAsync<LocationSelectionException>(() => d.ValidateAsync("US", "NOT_A_STATE"));
        var valid = await d.ValidateAsync("US", "CA"); Assert.Equal("California", valid.ProvinceName);
    }
    [Fact]
    public async Task Invalid_country_input_is_rejected_before_network_and_unknown_country_cannot_be_selected()
    {
        using var p = new Provider(); var d = p.Directory;
        await Assert.ThrowsAsync<LocationSelectionException>(() => d.GetProvincesAsync("https://localhost")); Assert.Equal(0, p.Calls);
        await Assert.ThrowsAsync<LocationSelectionException>(() => d.GetProvincesAsync("ZZ"));
    }
    [Fact]
    public async Task Concurrent_callers_share_one_provider_refresh_and_fresh_cache_avoids_requests()
    {
        using var p = new Provider { Gate = new(TaskCreationOptions.RunContinuationsAsynchronously) }; var d = p.Directory;
        var requests = Enumerable.Range(0, 20).Select(_ => d.GetCountriesAsync()).ToArray();
        p.Gate.SetResult(true); await Task.WhenAll(requests);
        Assert.Equal(3, p.Calls); await d.GetCountriesAsync(); Assert.Equal(3, p.Calls);
    }
    [Fact]
    public async Task One_cancelled_waiter_does_not_cancel_shared_refresh()
    {
        using var p = new Provider { Gate = new(TaskCreationOptions.RunContinuationsAsynchronously) }; var d = p.Directory;
        using var cancelled = new CancellationTokenSource(); var first = d.GetCountriesAsync(cancelled.Token);
        cancelled.Cancel(); await Assert.ThrowsAnyAsync<OperationCanceledException>(() => first);
        p.Gate.SetResult(true); var next = await d.GetCountriesAsync(); Assert.False(next.Stale); Assert.Equal(3, p.Calls);
    }
    [Fact]
    public async Task Outage_returns_old_snapshot_as_stale_without_resetting_asof_and_expires_after_seven_days()
    {
        using var p = new Provider(); var d = p.Directory; var initial = await d.GetCountriesAsync();
        p.Fail = true; p.Clock.Now += TimeSpan.FromHours(25);
        var stale = await d.GetCountriesAsync(); Assert.True(stale.Stale); Assert.Equal(initial.AsOf, stale.AsOf);
        var calls = p.Calls; await d.GetCountriesAsync(); Assert.Equal(calls, p.Calls);
        p.Clock.Now += TimeSpan.FromDays(7);
        await Assert.ThrowsAsync<LocationDirectoryUnavailableException>(() => d.GetCountriesAsync());
    }
    [Fact]
    public async Task Vietnam_refresh_failure_keeps_only_previously_verified_34_rows()
    {
        using var p = new Provider(); var d = p.Directory; var initial = await d.GetProvincesAsync("VN");
        p.VnCount = 63; p.Clock.Now += TimeSpan.FromHours(25);
        var stale = await d.GetProvincesAsync("VN"); Assert.True(stale.Stale); Assert.Equal(34, stale.Items.Count); Assert.Equal(initial.AsOf, stale.AsOf);
    }
    [Fact]
    public async Task Cold_outage_and_oversized_payload_fail_closed_with_a_retry_cooldown()
    {
        using var p = new Provider { Fail = true }; var d = p.Directory;
        await Assert.ThrowsAsync<LocationDirectoryUnavailableException>(() => d.GetCountriesAsync());
        var calls = p.Calls; await Assert.ThrowsAsync<LocationDirectoryUnavailableException>(() => d.GetCountriesAsync()); Assert.Equal(calls, p.Calls);
        using var huge = new Provider { TooLarge = true };
        await Assert.ThrowsAsync<LocationDirectoryUnavailableException>(() => huge.Directory.GetCountriesAsync());
    }
    [Fact]
    public async Task Missing_provider_fields_and_redirect_responses_fail_without_hanging_or_following()
    {
        using var malformed = new Provider { Malformed = true };
        await Assert.ThrowsAsync<LocationDirectoryUnavailableException>(() => malformed.Directory.GetCountriesAsync());
        using var redirect = new Provider { Redirect = true };
        await Assert.ThrowsAsync<LocationDirectoryUnavailableException>(() => redirect.Directory.GetCountriesAsync());
        Assert.DoesNotContain(redirect.Uris, uri => uri.Contains("127.0.0.1"));
    }
}
