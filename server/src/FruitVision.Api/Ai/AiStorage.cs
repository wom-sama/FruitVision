using System.Security.Cryptography;
using Microsoft.Extensions.Options;

namespace FruitVision.Api.Ai;

public sealed class AiUploadException(int status, string message) : Exception(message)
{
    public int Status { get; } = status;
}

public sealed class AiStorage(IOptions<AiOptions> options, IWebHostEnvironment environment, ILogger<AiStorage> logger)
{
    private string Root()
    {
        var configured = options.Value.DataRoot;
        if (!Path.IsPathFullyQualified(configured)) throw new AiUploadException(503, "Kho tệp AI chưa được cấu hình.");
        var root = Path.GetFullPath(configured);
        var webRoot = Path.GetFullPath(environment.WebRootPath ?? Path.Combine(environment.ContentRootPath, "wwwroot"));
        var relative = Path.GetRelativePath(webRoot, root);
        if (relative == "." || (!relative.StartsWith(".." + Path.DirectorySeparatorChar, StringComparison.Ordinal) &&
            relative != ".." && !Path.IsPathRooted(relative)))
            throw new AiUploadException(503, "Kho tệp AI phải nằm ngoài thư mục công khai.");
        return root;
    }

    public string DirectoryFor(Guid id)
    {
        var root = Root();
        var directory = Path.GetFullPath(Path.Combine(root, id.ToString("N")));
        if (!directory.StartsWith(root.TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar,
            OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal))
            throw new IOException("Invalid job directory.");
        if (Directory.Exists(directory) && (File.GetAttributes(directory) & FileAttributes.ReparsePoint) != 0)
            throw new IOException("Linked job directories are not accepted.");
        return directory;
    }

    public string InputFor(AiJob job) => Path.Combine(DirectoryFor(job.Id), "input" + job.InputExtension);
    public string PreviewFor(Guid id) => Path.Combine(DirectoryFor(id), "preview.jpg");

    public async Task SaveUploadAsync(AiJob job, Stream source, long limit, CancellationToken cancellationToken)
    {
        var directory = DirectoryFor(job.Id);
        Directory.CreateDirectory(directory);
        await using var file = new FileStream(InputFor(job), FileMode.CreateNew, FileAccess.Write, FileShare.None,
            65536, FileOptions.Asynchronous | FileOptions.SequentialScan);
        var digest = await TransferAsync(source, file, job.ContentType, limit, cancellationToken);
        job.InputBytes = digest.Bytes;
        job.InputSha256 = digest.Sha256;
    }

    public Task<(long Bytes, string Sha256)> HashUploadAsync(string contentType, Stream source,
        long limit, CancellationToken cancellationToken) =>
        TransferAsync(source, Stream.Null, contentType, limit, cancellationToken);

    private static async Task<(long Bytes, string Sha256)> TransferAsync(Stream source, Stream destination,
        string contentType, long limit, CancellationToken cancellationToken)
    {
        using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        var buffer = new byte[65536];
        var prefixLength = 0;
        while (prefixLength < 16)
        {
            var read = await source.ReadAsync(buffer.AsMemory(prefixLength, 16 - prefixLength), cancellationToken);
            if (read == 0) break;
            prefixLength += read;
        }
        if (!MagicMatches(contentType, buffer.AsSpan(0, prefixLength)))
            throw new AiUploadException(400, "Nội dung tệp không khớp loại ảnh hoặc video đã khai báo.");
        var total = (long)prefixLength;
        hash.AppendData(buffer, 0, prefixLength);
        await destination.WriteAsync(buffer.AsMemory(0, prefixLength), cancellationToken);
        while (true)
        {
            var read = await source.ReadAsync(buffer.AsMemory(), cancellationToken);
            if (read == 0) break;
            total += read;
            if (total > limit) throw new AiUploadException(413, "Tệp vượt giới hạn dung lượng.");
            hash.AppendData(buffer, 0, read);
            await destination.WriteAsync(buffer.AsMemory(0, read), cancellationToken);
        }
        await destination.FlushAsync(cancellationToken);
        return (total, Convert.ToHexString(hash.GetHashAndReset()).ToLowerInvariant());
    }

    public static bool MagicMatches(string contentType, ReadOnlySpan<byte> prefix) => contentType switch
    {
        "image/jpeg" => prefix.Length >= 3 && prefix[0] == 0xff && prefix[1] == 0xd8 && prefix[2] == 0xff,
        "image/png" => prefix.Length >= 8 && prefix[..8].SequenceEqual(new byte[] { 137, 80, 78, 71, 13, 10, 26, 10 }),
        "video/mp4" => prefix.Length >= 12 && prefix.Slice(4, 4).SequenceEqual("ftyp"u8),
        _ => false
    };

    public FileStream? OpenPreview(Guid id)
    {
        var path = PreviewFor(id);
        if (!File.Exists(path) || (File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0) return null;
        var file = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 65536,
            FileOptions.Asynchronous | FileOptions.SequentialScan);
        Span<byte> magic = stackalloc byte[3];
        if (file.Length is <= 3 or > 10 * 1024 * 1024 || file.Read(magic) != 3 || !MagicMatches("image/jpeg", magic))
        { file.Dispose(); return null; }
        file.Position = 0;
        return file;
    }

    public void RemoveIncomplete(Guid id)
    {
        // DirectoryFor resolves and checks the exact GUID child before recursive cleanup.
        var directory = DirectoryFor(id);
        if (Directory.Exists(directory)) Directory.Delete(directory, recursive: true);
    }

    public void RemoveInput(AiJob job)
    {
        try
        {
            var path = InputFor(job);
            if (File.Exists(path) && (File.GetAttributes(path) & FileAttributes.ReparsePoint) == 0) File.Delete(path);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or AiUploadException)
        { logger.LogWarning("Terminal AI job {JobId} input cleanup was not completed.", job.Id); }
    }
}
