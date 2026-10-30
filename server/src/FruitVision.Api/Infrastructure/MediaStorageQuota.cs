using FruitVision.Api.Data;
using System.Globalization;
using Microsoft.EntityFrameworkCore;

namespace FruitVision.Api.Infrastructure;

public sealed class MediaQuotaException(int status, string message) : Exception(message)
{
    public int Status { get; } = status;
}

public static class MediaStorageQuota
{
    private const long DefaultUserBytes = 100L * 1024 * 1024;
    private const long DefaultTotalBytes = 2L * 1024 * 1024 * 1024;
    private const long DefaultFreeBytes = 1024L * 1024 * 1024;
    private sealed class StoredBytes { public long UserBytes { get; set; } public long TotalBytes { get; set; } }

    private static long Limit(IConfiguration configuration, string name, long fallback)
    {
        var raw = configuration["MediaLimits:" + name];
        if (raw is null) return fallback;
        if (!long.TryParse(raw, NumberStyles.Integer, CultureInfo.InvariantCulture, out var value) || value <= 0)
            throw new MediaQuotaException(503, "Cấu hình hạn mức lưu trữ (storage quota) không hợp lệ. Liên hệ Admin.");
        return value;
    }

    /// <summary>Call in the caller's existing READ COMMITTED write transaction, after all domain
    /// locks and before moving/registering a NEW file. The global lock lasts until caller commit.
    /// Already registered idempotent retries must return before this admission check.</summary>
    public static async Task EnsureAsync(AppDbContext db, Guid ownerId, long incomingBytes, string storageRoot,
        IConfiguration configuration, CancellationToken cancellationToken)
    {
        if (db.Database.CurrentTransaction is null) throw new MediaQuotaException(503, "Chưa tạo giao dịch kiểm tra hạn mức lưu trữ. Liên hệ Admin.");
        if (ownerId == Guid.Empty || incomingBytes <= 0) throw new MediaQuotaException(400, "Dung lượng hoặc chủ tệp không hợp lệ.");
        var userLimit = Limit(configuration, "UserStoredBytes", DefaultUserBytes);
        var totalLimit = Limit(configuration, "TotalStoredBytes", DefaultTotalBytes);
        var minimumFree = Limit(configuration, "MinimumFreeDiskBytes", DefaultFreeBytes);
        var quotaLock = "global-media-quota";
        await db.Database.ExecuteSqlInterpolatedAsync($"SELECT pg_advisory_xact_lock(hashtextextended({quotaLock},0))", cancellationToken);
        // Metadata only: never read image bytes, ciphertext, keys or user profile fields.
        var stored = await db.Database.SqlQuery<StoredBytes>($"""
            SELECT COALESCE(SUM("SizeBytes"),0)::bigint AS "TotalBytes",
                   COALESCE(SUM(CASE WHEN "OwnerId"={ownerId} THEN "SizeBytes" ELSE 0 END),0)::bigint AS "UserBytes"
            FROM (
                SELECT "OwnerId", "SizeBytes" FROM "NormalImages"
                UNION ALL
                SELECT "UploaderUserId" AS "OwnerId", "SizeBytes" FROM "SecretAttachments"
            ) AS registered_media
            """).SingleAsync(cancellationToken);
        if (incomingBytes > userLimit || stored.UserBytes > userLimit - incomingBytes)
            throw new MediaQuotaException(409, "Đã chạm hạn mức lưu trữ (storage quota) của tài khoản. Liên hệ Admin; hệ thống không tự xóa lịch sử.");
        if (incomingBytes > totalLimit || stored.TotalBytes > totalLimit - incomingBytes)
            throw new MediaQuotaException(507, "Đã chạm hạn mức lưu trữ (storage quota) của máy chủ. Liên hệ Admin; hệ thống không tự xóa lịch sử.");
        long available;
        try
        {
            if (!Path.IsPathFullyQualified(storageRoot)) throw new IOException();
            var volume = Path.GetPathRoot(Path.GetFullPath(storageRoot));
            if (string.IsNullOrEmpty(volume)) throw new IOException();
            var drive = new DriveInfo(volume);
            if (!drive.IsReady) throw new IOException();
            available = drive.AvailableFreeSpace;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException or System.Security.SecurityException)
        {
            throw new MediaQuotaException(503, "Không kiểm tra được dung lượng ổ lưu tệp. Liên hệ Admin; chưa nhận tệp mới.");
        }
        // Conservative even when the caller has already staged bytes on this volume.
        if (available < minimumFree || incomingBytes > available - minimumFree)
            throw new MediaQuotaException(507, "Không đủ khoảng trống an toàn trên ổ lưu tệp. Liên hệ Admin; hệ thống không tự xóa lịch sử.");
    }
}
