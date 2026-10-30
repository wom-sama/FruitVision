using System.Security.Cryptography;
using FruitVision.Api.Data;
using Microsoft.Extensions.Options;

namespace FruitVision.Api.Infrastructure;

public sealed class SecretMessagesOptions { public string RootPath { get; set; } = ""; }
public sealed class SecretStorageException(int status, string message) : Exception(message) { public int Status { get; } = status; }

/// <summary>Opaque ciphertext storage. It deliberately does not decode/sanitize images or hold image keys.</summary>
public sealed class SecretAttachmentStorage(IOptions<SecretMessagesOptions> options, IWebHostEnvironment environment, ILogger<SecretAttachmentStorage> logger)
{
    public const long MaximumBytes = 5L * 1024 * 1024 + 65536;
    public string RootPath => options.Value.RootPath;
    private static void NoLinks(string path)
    {
        for (var current = path; !string.IsNullOrEmpty(current); current = Path.GetDirectoryName(current))
            if ((File.Exists(current) || Directory.Exists(current)) && (File.GetAttributes(current) & FileAttributes.ReparsePoint) != 0)
                throw new SecretStorageException(503, "Kho tệp bí mật chưa sẵn sàng.");
    }
    private string FileFor(SecretAttachment attachment, bool create)
    {
        var configured = options.Value.RootPath;
        if (string.IsNullOrWhiteSpace(configured) || !Path.IsPathFullyQualified(configured)) throw new SecretStorageException(503, "Kho tệp bí mật chưa được cấu hình.");
        var root = Path.TrimEndingDirectorySeparator(Path.GetFullPath(configured));
        var web = Path.TrimEndingDirectorySeparator(Path.GetFullPath(environment.WebRootPath ?? Path.Combine(environment.ContentRootPath, "wwwroot")));
        var comparison = OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal;
        if (root.Equals(web, comparison) || root.StartsWith(web + Path.DirectorySeparatorChar, comparison)) throw new SecretStorageException(503, "Kho tệp bí mật không được đặt trong thư mục công khai.");
        var directory = Path.Combine(root, attachment.ConversationId.ToString("N"));
        NoLinks(directory);
        if (create) { Directory.CreateDirectory(directory); NoLinks(directory); }
        var path = Path.Combine(directory, attachment.Id.ToString("N") + ".bin");
        NoLinks(path);
        return path;
    }
    public async Task SaveAsync(SecretAttachment attachment, Stream source, CancellationToken ct)
    {
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(ct);
        deadline.CancelAfter(TimeSpan.FromSeconds(45));
        var path = FileFor(attachment, true); var complete = false;
        try
        {
            await using var file = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None, 65536, FileOptions.Asynchronous | FileOptions.SequentialScan);
            using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
            var buffer = new byte[65536]; long total = 0;
            while (true)
            {
                var read = await source.ReadAsync(buffer.AsMemory(), deadline.Token);
                if (read == 0) break;
                total += read;
                if (total > MaximumBytes) throw new SecretStorageException(413, "Tệp mã hóa vượt giới hạn 5 MiB cộng phần phụ trội cho phép.");
                hash.AppendData(buffer, 0, read);
                await file.WriteAsync(buffer.AsMemory(0, read), deadline.Token);
            }
            if (total == 0) throw new SecretStorageException(400, "Tệp mã hóa không được rỗng.");
            await file.FlushAsync(deadline.Token);
            attachment.SizeBytes = total; attachment.Sha256 = Convert.ToHexString(hash.GetHashAndReset()).ToLowerInvariant(); complete = true;
        }
        catch (OperationCanceledException) when (!ct.IsCancellationRequested) { throw new SecretStorageException(408, "Tải tệp mã hóa quá thời gian cho phép."); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { throw new SecretStorageException(503, "Chưa lưu được tệp mã hóa."); }
        finally { if (!complete) Remove(attachment); }
    }
    public async Task<FileStream?> OpenAsync(SecretAttachment attachment, CancellationToken ct)
    {
        FileStream? file = null;
        try
        {
            var path = FileFor(attachment, false);
            if (!File.Exists(path) || attachment.SizeBytes is <= 0 or > MaximumBytes) return null;
            file = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 65536, FileOptions.Asynchronous | FileOptions.SequentialScan);
            if (file.Length != attachment.SizeBytes || !Convert.ToHexString(await SHA256.HashDataAsync(file, ct)).Equals(attachment.Sha256, StringComparison.OrdinalIgnoreCase)) return null;
            file.Position = 0; var verified = file; file = null; return verified;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or SecretStorageException) { return null; }
        finally { if (file is not null) await file.DisposeAsync(); }
    }
    public void Remove(SecretAttachment attachment)
    {
        try { var path = FileFor(attachment, false); if (File.Exists(path)) File.Delete(path); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or SecretStorageException)
        { logger.LogWarning("Unregistered encrypted attachment {AttachmentId} cleanup did not complete.", attachment.Id); }
    }
}
