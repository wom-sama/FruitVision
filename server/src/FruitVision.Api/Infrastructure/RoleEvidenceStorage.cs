using System.Security.Cryptography;
using FruitVision.Api.Data;
using Microsoft.Extensions.Options;

namespace FruitVision.Api.Infrastructure;

public sealed class RoleEvidenceOptions
{
    public string RootPath { get; set; } = "";
}

public sealed class RoleEvidenceException(int status, string message) : Exception(message)
{
    public int Status { get; } = status;
}

/// <summary>Private, bounded document storage. Signature checks are not malware scanning.</summary>
public sealed class RoleEvidenceStorage(IOptions<RoleEvidenceOptions> options, IWebHostEnvironment environment, ILogger<RoleEvidenceStorage> logger)
{
    public const long MaximumBytes = 5L * 1024 * 1024;
    public static string? Extension(string? contentType) => contentType switch
    {
        "image/jpeg" => ".jpg", "image/png" => ".png", "application/pdf" => ".pdf", _ => null
    };

    private static void RejectLinks(string path)
    {
        for (var current = path; !string.IsNullOrEmpty(current); current = Path.GetDirectoryName(current))
            if ((Directory.Exists(current) || File.Exists(current)) && (File.GetAttributes(current) & FileAttributes.ReparsePoint) != 0)
                throw new RoleEvidenceException(503, "Kho minh chứng chưa sẵn sàng.");
    }

    private string FileFor(RoleApplicationEvidence evidence, bool create)
    {
        var configured = options.Value.RootPath;
        if (string.IsNullOrWhiteSpace(configured) || !Path.IsPathFullyQualified(configured))
            throw new RoleEvidenceException(503, "Kho minh chứng chưa được cấu hình.");
        var root = Path.TrimEndingDirectorySeparator(Path.GetFullPath(configured));
        var webRoot = Path.TrimEndingDirectorySeparator(Path.GetFullPath(environment.WebRootPath ?? Path.Combine(environment.ContentRootPath, "wwwroot")));
        var comparison = OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal;
        if (root.Equals(webRoot, comparison) || root.StartsWith(webRoot + Path.DirectorySeparatorChar, comparison))
            throw new RoleEvidenceException(503, "Kho minh chứng phải nằm ngoài thư mục công khai.");
        var extension = Extension(evidence.ContentType) ?? throw new RoleEvidenceException(400, "Chỉ nhận JPEG, PNG hoặc PDF.");
        var directory = Path.Combine(root, evidence.ApplicationId.ToString("N"));
        RejectLinks(directory);
        if (create) { Directory.CreateDirectory(directory); RejectLinks(directory); }
        var path = Path.Combine(directory, evidence.Id.ToString("N") + extension);
        RejectLinks(path);
        return path;
    }

    public async Task SaveAsync(RoleApplicationEvidence evidence, Stream source, CancellationToken cancellationToken)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(TimeSpan.FromSeconds(45));
        var path = FileFor(evidence, true);
        var completed = false;
        try
        {
            await using var output = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None, 65536, FileOptions.Asynchronous | FileOptions.SequentialScan);
            using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
            var buffer = new byte[65536];
            var prefix = 0;
            while (prefix < 16)
            {
                var read = await source.ReadAsync(buffer.AsMemory(prefix, 16 - prefix), timeout.Token);
                if (read == 0) break;
                prefix += read;
            }
            if (!Signature(evidence.ContentType, buffer.AsSpan(0, prefix)))
                throw new RoleEvidenceException(400, "Nội dung không khớp loại JPEG, PNG hoặc PDF đã khai báo.");
            long total = prefix;
            hash.AppendData(buffer, 0, prefix);
            await output.WriteAsync(buffer.AsMemory(0, prefix), timeout.Token);
            while (true)
            {
                var read = await source.ReadAsync(buffer.AsMemory(), timeout.Token);
                if (read == 0) break;
                total += read;
                if (total > MaximumBytes) throw new RoleEvidenceException(413, "Minh chứng tối đa 5 MiB mỗi tệp.");
                hash.AppendData(buffer, 0, read);
                await output.WriteAsync(buffer.AsMemory(0, read), timeout.Token);
            }
            await output.FlushAsync(timeout.Token);
            evidence.SizeBytes = total;
            evidence.Sha256 = Convert.ToHexString(hash.GetHashAndReset()).ToLowerInvariant();
            completed = true;
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            throw new RoleEvidenceException(408, "Tải minh chứng quá thời gian cho phép.");
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            throw new RoleEvidenceException(503, "Không lưu được minh chứng. Vui lòng thử lại.");
        }
        finally
        {
            if (!completed) Remove(evidence);
        }
    }

    private static bool Signature(string contentType, ReadOnlySpan<byte> prefix) => contentType switch
    {
        "image/jpeg" => prefix.Length >= 3 && prefix[0] == 255 && prefix[1] == 216 && prefix[2] == 255,
        "image/png" => prefix.Length >= 8 && prefix[..8].SequenceEqual(new byte[] { 137, 80, 78, 71, 13, 10, 26, 10 }),
        "application/pdf" => prefix.Length >= 8 && prefix[..5].SequenceEqual("%PDF-"u8) && prefix[5] is (byte)'1' or (byte)'2' && prefix[6] == (byte)'.' && prefix[7] is >= (byte)'0' and <= (byte)'9',
        _ => false
    };

    public async Task<FileStream?> OpenAsync(RoleApplicationEvidence evidence, CancellationToken cancellationToken)
    {
        FileStream? file = null;
        try
        {
            var path = FileFor(evidence, false);
            if (!File.Exists(path) || evidence.SizeBytes is <= 0 or > MaximumBytes) return null;
            file = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 65536, FileOptions.Asynchronous | FileOptions.SequentialScan);
            if (file.Length != evidence.SizeBytes) return null;
            var actual = await SHA256.HashDataAsync(file, cancellationToken);
            if (!string.Equals(Convert.ToHexString(actual), evidence.Sha256, StringComparison.OrdinalIgnoreCase)) return null;
            file.Position = 0;
            var verified = file; file = null; return verified;
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or RoleEvidenceException)
        {
            return null;
        }
        finally { if (file is not null) await file.DisposeAsync(); }
    }

    public void Remove(RoleApplicationEvidence evidence)
    {
        try
        {
            var path = FileFor(evidence, false);
            if (File.Exists(path)) File.Delete(path);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or RoleEvidenceException)
        {
            logger.LogWarning("Private evidence {EvidenceId} cleanup was not completed.", evidence.Id);
        }
    }
}
