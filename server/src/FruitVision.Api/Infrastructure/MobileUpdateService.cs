using System.Globalization;
using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Serialization;
using Microsoft.Extensions.Options;

namespace FruitVision.Api.Infrastructure;

public sealed class MobileUpdateOptions
{
    public string RootPath { get; set; } = "";
}

public sealed record MobileUpdateInfo(int SchemaVersion, bool UpdateServiceEnabled, bool Available, bool Mandatory,
    string? LatestVersionName, long? LatestVersionCode, long? MinimumSupportedVersionCode,
    long? ApkSizeBytes, string? Sha256, string? DownloadPath, string? Notes, DateTimeOffset? PublishedAt);

/// <summary>Reads operator-published local registrations; never accepts a client file path or fetches a URL.</summary>
public sealed class MobileUpdateService(IOptions<MobileUpdateOptions> options, IWebHostEnvironment environment)
{
    private const long MaximumApkBytes = 80L * 1024 * 1024;
    private const long MaximumManifestBytes = 64 * 1024;
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web)
    {
        PropertyNameCaseInsensitive = false,
        UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow,
        MaxDepth = 8
    };
    private static readonly MobileUpdateInfo Disabled = new(1, false, false, false, null, null, null, null, null, null, null, null);

    public static bool KnownAbi(string? abi) => abi is "arm64-v8a" or "armeabi-v7a" or "x86_64";

    public async Task<MobileUpdateInfo> CheckAsync(long currentVersion, string abi, CancellationToken cancellationToken)
    {
        var root = GetPrivateRoot();
        if (root is null) return Disabled;
        var manifest = await ReadManifestAsync(root, null, cancellationToken);
        if (manifest is null) return Disabled;
        var artifact = manifest.Artifacts!.SingleOrDefault(item => item.Abi == abi);
        if (artifact is not null)
        {
            // Do not advertise a missing or changed file. No cache is used: atomic publisher replacements
            // and file tampering are observed on the next check, including same-size modifications.
            await using var verified = await OpenVerifiedAsync(root, manifest.VersionCode, artifact, cancellationToken);
            if (verified is null) return Disabled;
        }
        return new(1, true, artifact is not null && manifest.VersionCode > currentVersion,
            currentVersion < manifest.MinimumSupportedVersionCode, manifest.VersionName, manifest.VersionCode,
            manifest.MinimumSupportedVersionCode, artifact?.SizeBytes, artifact?.Sha256?.ToLowerInvariant(),
            artifact is null ? null : $"/api/v1/mobile/releases/{manifest.VersionCode.ToString(CultureInfo.InvariantCulture)}/{abi}.apk",
            manifest.Notes, manifest.PublishedAt);
    }

    public async Task<FileStream?> OpenDownloadAsync(long versionCode, string abi, CancellationToken cancellationToken)
    {
        if (versionCode <= 0 || !KnownAbi(abi)) return null;
        var root = GetPrivateRoot();
        if (root is null) return null;
        var manifest = await ReadManifestAsync(root, versionCode, cancellationToken);
        var artifact = manifest?.Artifacts?.SingleOrDefault(item => item.Abi == abi);
        return artifact is null ? null : await OpenVerifiedAsync(root, versionCode, artifact, cancellationToken);
    }

    private string? GetPrivateRoot()
    {
        try
        {
            var configured = options.Value.RootPath;
            if (string.IsNullOrWhiteSpace(configured) || !Path.IsPathFullyQualified(configured)) return null;
            var root = Path.TrimEndingDirectorySeparator(Path.GetFullPath(configured));
            var webRoot = Path.TrimEndingDirectorySeparator(Path.GetFullPath(environment.WebRootPath ?? Path.Combine(environment.ContentRootPath, "wwwroot")));
            var comparison = OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal;
            if (root.Equals(webRoot, comparison) || root.StartsWith(webRoot + Path.DirectorySeparatorChar, comparison)) return null;
            return Directory.Exists(root) && NoLinks(root) ? root : null;
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException)
        {
            return null;
        }
    }

    private static async Task<ReleaseManifest?> ReadManifestAsync(string root, long? versionCode, CancellationToken cancellationToken)
    {
        try
        {
            var snapshot = versionCode.HasValue ? Path.Combine(root, versionCode.Value.ToString(CultureInfo.InvariantCulture), "manifest.json") : null;
            // Old release URLs are registered by immutable per-version snapshots. A matching latest
            // manifest also works for the initial publisher; arbitrary folders alone register nothing.
            var path = snapshot is not null && File.Exists(snapshot) ? snapshot : Path.Combine(root, "manifest.json");
            if (!File.Exists(path) || !NoLinks(path)) return null;
            await using var file = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read | FileShare.Delete, 8192, FileOptions.Asynchronous | FileOptions.SequentialScan);
            if (file.Length is <= 0 or > MaximumManifestBytes) return null;
            var manifest = await JsonSerializer.DeserializeAsync<ReleaseManifest>(file, JsonOptions, cancellationToken);
            return Valid(manifest) && (!versionCode.HasValue || manifest!.VersionCode == versionCode.Value) ? manifest : null;
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or JsonException or ArgumentException or NotSupportedException)
        {
            return null;
        }
    }

    private static bool Valid(ReleaseManifest? manifest)
    {
        if (manifest is null || manifest.SchemaVersion != 1 || manifest.PackageName != "vn.mangodemo.mango_offline" ||
            manifest.VersionCode <= 0 || manifest.MinimumSupportedVersionCode <= 0 || manifest.MinimumSupportedVersionCode > manifest.VersionCode ||
            string.IsNullOrWhiteSpace(manifest.VersionName) || manifest.VersionName.Length > 100 || manifest.VersionName.Any(char.IsControl) ||
            manifest.Notes is null || manifest.Notes.Length > 4000 || manifest.Notes.Any(c => char.IsControl(c) && c is not ('\n' or '\r' or '\t')) ||
            manifest.PublishedAt == default || manifest.Artifacts is null || manifest.Artifacts.Length is < 1 or > 3) return false;
        var abis = new HashSet<string>(StringComparer.Ordinal);
        var files = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        return manifest.Artifacts.All(item => item is not null && KnownAbi(item.Abi) && abis.Add(item.Abi!) &&
            SafeLeaf(item.FileName) && files.Add(item.FileName!) && item.SizeBytes is > 0 and <= MaximumApkBytes &&
            item.Sha256 is { Length: 64 } && item.Sha256.All(Uri.IsHexDigit));
    }

    private static bool SafeLeaf(string? name) => name is { Length: >= 5 and <= 160 } &&
        char.IsAsciiLetterOrDigit(name[0]) && name.EndsWith(".apk", StringComparison.Ordinal) &&
        name.All(c => char.IsAsciiLetterOrDigit(c) || c is '.' or '-' or '_') &&
        !new[] { "CON", "PRN", "AUX", "NUL", "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9", "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9" }
            .Contains(name.Split('.')[0], StringComparer.OrdinalIgnoreCase);

    private static bool NoLinks(string path)
    {
        // A safe leaf is insufficient if the operator directory or artifact is a junction/symlink.
        for (var current = path; !string.IsNullOrEmpty(current); current = Path.GetDirectoryName(current))
            if ((File.GetAttributes(current) & FileAttributes.ReparsePoint) != 0) return false;
        return true;
    }

    private static async Task<FileStream?> OpenVerifiedAsync(string root, long versionCode, ReleaseArtifact artifact, CancellationToken cancellationToken)
    {
        FileStream? file = null;
        try
        {
            var path = Path.Combine(root, versionCode.ToString(CultureInfo.InvariantCulture), artifact.FileName!);
            if (!File.Exists(path) || !NoLinks(path)) return null;
            // Keep the same open handle from verification through Range streaming; deny concurrent
            // writes/replacement on the Windows demo host instead of reopening a checked pathname.
            file = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 65536, FileOptions.Asynchronous | FileOptions.SequentialScan);
            if (file.Length != artifact.SizeBytes) return null;
            var actual = await SHA256.HashDataAsync(file, cancellationToken);
            if (!CryptographicOperations.FixedTimeEquals(actual, Convert.FromHexString(artifact.Sha256!))) return null;
            file.Position = 0;
            var verified = file;
            file = null;
            return verified;
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException)
        {
            return null;
        }
        finally
        {
            if (file is not null) await file.DisposeAsync();
        }
    }

    private sealed class ReleaseManifest
    {
        public int SchemaVersion { get; set; }
        public string? PackageName { get; set; }
        public string? VersionName { get; set; }
        public long VersionCode { get; set; }
        public long MinimumSupportedVersionCode { get; set; }
        public string? Notes { get; set; }
        public DateTimeOffset PublishedAt { get; set; }
        public ReleaseArtifact[]? Artifacts { get; set; }
    }

    private sealed class ReleaseArtifact
    {
        public string? Abi { get; set; }
        public string? FileName { get; set; }
        public long SizeBytes { get; set; }
        public string? Sha256 { get; set; }
    }
}
