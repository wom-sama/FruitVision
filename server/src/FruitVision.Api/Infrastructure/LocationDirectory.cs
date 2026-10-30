using System.Collections.Concurrent;
using System.Globalization;
using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace FruitVision.Api.Infrastructure;

public sealed record LocationItem(string Code, string Name, string CodeKind);
public sealed record LocationDirectoryResponse(IReadOnlyList<LocationItem> Items, string Source,
    DateTimeOffset AsOf, bool Stale, string? CountryCode = null);
public sealed record ValidatedLocation(string CountryCode, string ProvinceCode, string CountryName,
    string ProvinceName, string Region, string Source, DateTimeOffset AsOf, bool Stale);
public sealed class LocationSelectionException(string message) : Exception(message) { }
public sealed class LocationDirectoryUnavailableException() : Exception("Danh mục địa điểm chưa sẵn sàng. Vui lòng thử lại sau.") { }

/// <summary>
/// Reference directory only: AsOf is the last successful retrieval time, not a legal effective date.
/// Fresh for24h; a verified snapshot is usable during outage up to7days from AsOf, never rejuvenated.
/// Each refresh is shared, bounded12s, and independent of an individual caller's disconnection.
/// Providers: restcountries.com/docs/countries/api-versions (legacy may return200+errors);
/// github.com/MartinsOnuoha/countriesNowAPI; provinces.open-api.vn (v2, post07/2025);
/// github.com/unicode-org/cldr-json (Vietnamese territory labels).
/// </summary>
public sealed class LocationDirectory(IHttpClientFactory factory, TimeProvider? clock = null)
{
    public const string HttpClientName = "Locations";
    private const int MaxResponseBytes = 2 * 1024 * 1024;
    private static readonly TimeSpan Fresh = TimeSpan.FromHours(24), MaxAge = TimeSpan.FromDays(7), Retry = TimeSpan.FromMinutes(1);
    private const string RestUrl = "https://restcountries.com/v3.1/all?fields=cca2,name,translations";
    private const string GlobalUrl = "https://countriesnow.space/api/v0.1/countries/states";
    private const string VietnamUrl = "https://provinces.open-api.vn/api/v2/";
    private const string LabelsUrl = "https://raw.githubusercontent.com/unicode-org/cldr-json/main/cldr-json/cldr-localenames-full/main/vi/territories.json";
    private readonly TimeProvider time = clock ?? TimeProvider.System;
    private readonly Slot<LocationItem[]> countries = new();
    private readonly Slot<GlobalCountry[]> global = new();
    private readonly Slot<Dictionary<string, string>> labels = new();
    private readonly ConcurrentDictionary<string, Slot<LocationItem[]>> provinces = new(StringComparer.Ordinal);
    private sealed record GlobalCountry(string Code, string Name, State[] States);
    private sealed record State(string Name, string Code);
    private sealed record Snapshot<T>(T Value, string Source, DateTimeOffset AsOf);
    private sealed class Slot<T>
    {
        internal readonly object Gate = new();
        internal Snapshot<T>? Data;
        internal Task<Snapshot<T>>? Flight;
        internal DateTimeOffset NextAttempt;
    }

    public async Task<LocationDirectoryResponse> GetCountriesAsync(CancellationToken cancellationToken = default)
    {
        var snapshot = await Cached(countries, LoadCountries, cancellationToken);
        return View(snapshot);
    }
    public async Task<LocationDirectoryResponse> GetProvincesAsync(string? countryCode, CancellationToken cancellationToken = default)
    {
        var code = NormalizeCountry(countryCode);
        var known = await GetCountriesAsync(cancellationToken);
        if (!known.Items.Any(item => item.Code == code)) throw new LocationSelectionException("Quốc gia không có trong danh mục.");
        var slot = provinces.GetOrAdd(code, _ => new());
        var snapshot = await Cached(slot, token => LoadProvinces(code, token), cancellationToken);
        return View(snapshot, code);
    }
    public async Task<ValidatedLocation> ValidateAsync(string? countryCode, string? provinceCode, CancellationToken cancellationToken = default)
    {
        var code = NormalizeCountry(countryCode);
        if (string.IsNullOrWhiteSpace(provinceCode) || provinceCode.Length > 80 || provinceCode.Any(char.IsControl))
            throw new LocationSelectionException("Hãy chọn tỉnh/thành từ danh mục.");
        var province = provinceCode.Trim();
        var known = await GetCountriesAsync(cancellationToken);
        var country = known.Items.SingleOrDefault(item => item.Code == code)
            ?? throw new LocationSelectionException("Quốc gia không có trong danh mục.");
        var subdivision = await GetProvincesAsync(code, cancellationToken);
        var selected = subdivision.Items.SingleOrDefault(item => item.Code == province)
            ?? throw new LocationSelectionException("Tỉnh/thành không thuộc quốc gia đã chọn hoặc không có trong danh mục.");
        return new(code, selected.Code, country.Name, selected.Name, $"{selected.Name}, {country.Name}",
            $"{known.Source}; {subdivision.Source}", Earlier(known.AsOf, subdivision.AsOf), known.Stale || subdivision.Stale);
    }
    private LocationDirectoryResponse View(Snapshot<LocationItem[]> value, string? code = null) =>
        new(Array.AsReadOnly(value.Value), value.Source, value.AsOf, time.GetUtcNow() - value.AsOf >= Fresh, code);
    private static string NormalizeCountry(string? code)
    {
        var value = code?.Trim().ToUpperInvariant();
        if (value is null || value.Length != 2 || value.Any(c => c is < 'A' or > 'Z'))
            throw new LocationSelectionException("Mã quốc gia cần có2chữ cái theo danh mục.");
        return value;
    }
    private static DateTimeOffset Earlier(DateTimeOffset a, DateTimeOffset b) => a < b ? a : b;

    private async Task<Snapshot<T>> Cached<T>(Slot<T> slot, Func<CancellationToken, Task<Snapshot<T>>> load, CancellationToken caller)
    {
        caller.ThrowIfCancellationRequested();
        TaskCompletionSource<Snapshot<T>>? start = null;
        Task<Snapshot<T>> task;
        lock (slot.Gate)
        {
            var now = time.GetUtcNow();
            if (slot.Data is { } cached && now - cached.AsOf < Fresh) return cached;
            if (slot.Flight is not null) task = slot.Flight;
            else if (now < slot.NextAttempt)
                return slot.Data is { } old && now - old.AsOf <= MaxAge ? old : throw new LocationDirectoryUnavailableException();
            else
            {
                start = new(TaskCreationOptions.RunContinuationsAsynchronously);
                task = slot.Flight = start.Task;
            }
        }
        if (start is not null) _ = Refresh(slot, start, load);
        return await task.WaitAsync(caller);
    }
    private async Task Refresh<T>(Slot<T> slot, TaskCompletionSource<Snapshot<T>> completion, Func<CancellationToken, Task<Snapshot<T>>> load)
    {
        try
        {
            using var budget = new CancellationTokenSource(TimeSpan.FromSeconds(12));
            var value = await load(budget.Token);
            lock (slot.Gate)
            {
                slot.Data = value;
                slot.NextAttempt = time.GetUtcNow() + Retry;
            }
            completion.TrySetResult(value);
        }
        catch (Exception error) when (error is HttpRequestException or IOException or InvalidDataException or JsonException or OperationCanceledException or InvalidOperationException or FormatException or KeyNotFoundException or LocationSelectionException or ArgumentException or OverflowException)
        {
            Snapshot<T>? stale;
            lock (slot.Gate)
            {
                slot.NextAttempt = time.GetUtcNow() + Retry;
                stale = slot.Data is { } old && time.GetUtcNow() - old.AsOf <= MaxAge ? old : null;
            }
            if (stale is not null) completion.TrySetResult(stale);
            else completion.TrySetException(new LocationDirectoryUnavailableException());
        }
        catch (LocationDirectoryUnavailableException)
        {
            Snapshot<T>? stale;
            lock (slot.Gate)
            {
                slot.NextAttempt = time.GetUtcNow() + Retry;
                stale = slot.Data is { } old && time.GetUtcNow() - old.AsOf <= MaxAge ? old : null;
            }
            if (stale is not null) completion.TrySetResult(stale);
            else completion.TrySetException(new LocationDirectoryUnavailableException());
        }
        catch (Exception error)
        {
            // Do not leave shared callers waiting forever if a programming failure escapes the parser.
            // Unexpected failures remain visible to the application's error handler/test runner.
            completion.TrySetException(error);
        }
        finally
        {
            lock (slot.Gate) if (ReferenceEquals(slot.Flight, completion.Task)) slot.Flight = null;
        }
    }

    private async Task<JsonDocument> Json(string address, CancellationToken token)
    {
        // All addresses are fixed constants; no user URL, country path interpolation or credential forwarding.
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(token);
        deadline.CancelAfter(TimeSpan.FromSeconds(address == RestUrl ? 2 : 4));
        using var client = factory.CreateClient(HttpClientName);
        using var request = new HttpRequestMessage(HttpMethod.Get, address);
        request.Headers.Accept.ParseAdd("application/json");
        using var response = await client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, deadline.Token);
        response.EnsureSuccessStatusCode();
        if (response.Content.Headers.ContentLength > MaxResponseBytes) throw new InvalidDataException("Location payload too large.");
        await using var input = await response.Content.ReadAsStreamAsync(deadline.Token);
        using var output = new MemoryStream();
        var buffer = new byte[16384];
        int count;
        while ((count = await input.ReadAsync(buffer, deadline.Token)) != 0)
        {
            if (output.Length + count > MaxResponseBytes) throw new InvalidDataException("Location payload too large.");
            await output.WriteAsync(buffer.AsMemory(0, count), deadline.Token);
        }
        return JsonDocument.Parse(output.ToArray(), new JsonDocumentOptions { MaxDepth = 16 });
    }
    private static string Text(JsonElement row, string key, int maximum = 140)
    {
        if (!row.TryGetProperty(key, out var value) || value.ValueKind != JsonValueKind.String)
            throw new InvalidDataException("Missing location label.");
        var text = value.GetString()!.Trim().Normalize(NormalizationForm.FormC);
        if (text.Length == 0 || text.Length > maximum || text.Any(char.IsControl)) throw new InvalidDataException("Invalid location label.");
        return text;
    }
    private async Task<Snapshot<LocationItem[]>> LoadCountries(CancellationToken token)
    {
        List<(string Code, string Name)> found;
        var source = "REST Countries";
        var asOf = time.GetUtcNow();
        try
        {
            using var document = await Json(RestUrl, token);
            if (document.RootElement.ValueKind != JsonValueKind.Array) throw new InvalidDataException("Legacy API unavailable.");
            found = document.RootElement.EnumerateArray().Select(row => (NormalizeCountry(Text(row, "cca2", 2)),
                Text(row.GetProperty("name"), "common"))).ToList();
            CheckCountries(found.Select(row => row.Code));
        }
        catch (Exception error) when (error is HttpRequestException or IOException or InvalidDataException or JsonException or OperationCanceledException or InvalidOperationException or KeyNotFoundException or LocationSelectionException)
        {
            var backup = await Cached(global, LoadGlobal, token);
            found = backup.Value.Select(row => (row.Code, row.Name)).ToList();
            source = backup.Source; asOf = backup.AsOf;
        }
        var names = await Cached(labels, LoadLabels, token);
        var items = found.Select(row => new LocationItem(row.Code,
            names.Value.GetValueOrDefault(row.Code) ?? row.Name, "providerCountryCode"))
            .OrderBy(row => row.Name, StringComparer.Create(CultureInfo.GetCultureInfo("vi-VN"), false)).ToArray();
        return new(items, source + "; Unicode CLDR vi (missing translation: provider label)", Earlier(asOf, names.AsOf));
    }
    private static void CheckCountries(IEnumerable<string> values)
    {
        var codes = values.ToArray();
        if (codes.Length is < 100 or > 300 || codes.Distinct(StringComparer.Ordinal).Count() != codes.Length || !codes.Contains("VN"))
            throw new InvalidDataException("Country directory incomplete.");
    }
    private async Task<Snapshot<Dictionary<string, string>>> LoadLabels(CancellationToken token)
    {
        using var document = await Json(LabelsUrl, token);
        var values = document.RootElement.GetProperty("main").GetProperty("vi").GetProperty("localeDisplayNames").GetProperty("territories");
        var translated = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var property in values.EnumerateObject())
        {
            if (!Regex.IsMatch(property.Name, "^[A-Z]{2}$", RegexOptions.CultureInvariant)) continue;
            translated.Add(property.Name, Text(values, property.Name));
        }
        if (translated.Count < 100 || !translated.ContainsKey("VN")) throw new InvalidDataException("Country translations incomplete.");
        return new(translated, "Unicode CLDR vi", time.GetUtcNow());
    }
    private async Task<Snapshot<GlobalCountry[]>> LoadGlobal(CancellationToken token)
    {
        using var document = await Json(GlobalUrl, token);
        var root = document.RootElement;
        if (root.GetProperty("error").ValueKind != JsonValueKind.False || root.GetProperty("data").ValueKind != JsonValueKind.Array)
            throw new InvalidDataException("Global directory unavailable.");
        var result = new List<GlobalCountry>();
        foreach (var row in root.GetProperty("data").EnumerateArray())
        {
            var code = NormalizeCountry(Text(row, "iso2", 2));
            var states = row.GetProperty("states");
            if (states.ValueKind != JsonValueKind.Array || states.GetArrayLength() > 1000) throw new InvalidDataException("Invalid state list.");
            result.Add(new(code, Text(row, "name"), states.EnumerateArray().Select(state => new State(Text(state, "name"),
                state.TryGetProperty("state_code", out var stateCode) && stateCode.ValueKind == JsonValueKind.String
                    ? stateCode.GetString()!.Trim() : "")).ToArray()));
        }
        CheckCountries(result.Select(row => row.Code));
        return new(result.ToArray(), "CountriesNow /api/v0.1/countries/states", time.GetUtcNow());
    }
    private async Task<Snapshot<LocationItem[]>> LoadProvinces(string country, CancellationToken token)
    {
        if (country == "VN")
        {
            using var document = await Json(VietnamUrl, token);
            if (document.RootElement.ValueKind != JsonValueKind.Array || document.RootElement.GetArrayLength() != 34)
                throw new InvalidDataException("Expected current34 Vietnamese provinces, never legacy63.");
            var items = document.RootElement.EnumerateArray().Select(row =>
            {
                var code = row.GetProperty("code").GetInt32();
                if (code is < 1 or > 99) throw new InvalidDataException("Invalid VN administrative code.");
                return new LocationItem(code.ToString("D2", CultureInfo.InvariantCulture), Text(row, "name"), "vnAdministrativeCode");
            }).ToArray();
            if (items.Select(row => row.Code).Distinct().Count() != 34) throw new InvalidDataException("Duplicate VN province.");
            return new(items.OrderBy(row => row.Name, StringComparer.Create(CultureInfo.GetCultureInfo("vi-VN"), false)).ToArray(), VietnamUrl, time.GetUtcNow());
        }
        var snapshot = await Cached(global, LoadGlobal, token);
        var data = snapshot.Value.SingleOrDefault(row => row.Code == country)
            ?? throw new InvalidDataException("Country missing from subdivision provider.");
        var distinct = data.States.Distinct().ToArray();
        var groups = distinct.GroupBy(state => state.Code, StringComparer.Ordinal).ToDictionary(g => g.Key, g => g.Count(), StringComparer.Ordinal);
        var foreign = distinct.Select(state =>
        {
            var providerCode = state.Code.Length is > 0 and <= 64 && !state.Code.Any(char.IsControl) &&
                !state.Code.StartsWith("ref:", StringComparison.Ordinal) && groups[state.Code] == 1;
            var code = providerCode ? state.Code : "ref:" + country + ":" +
                Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(state.Code + "\n" + state.Name)))[..24].ToLowerInvariant();
            return new LocationItem(code, state.Name, providerCode ? "providerStateCode" : "internalReference");
        }).OrderBy(row => row.Name, StringComparer.Ordinal).ToArray();
        return new(foreign, snapshot.Source + " (state codes are provider references, not certified ISO3166-2)", snapshot.AsOf);
    }
}

public static class LocationDirectoryRegistration
{
    public static IServiceCollection AddLocationDirectory(this IServiceCollection services)
    {
        services.AddHttpClient(LocationDirectory.HttpClientName, client => client.Timeout = Timeout.InfiniteTimeSpan)
            .ConfigurePrimaryHttpMessageHandler(() => new SocketsHttpHandler
            {
                AllowAutoRedirect = false, ConnectTimeout = TimeSpan.FromSeconds(3),
                AutomaticDecompression = DecompressionMethods.GZip | DecompressionMethods.Deflate,
                PooledConnectionLifetime = TimeSpan.FromMinutes(10)
            });
        services.AddSingleton<LocationDirectory>();
        return services;
    }
}
