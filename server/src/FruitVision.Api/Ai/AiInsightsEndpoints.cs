using System.Globalization;
using FruitVision.Api.Auth;
using FruitVision.Api.Data;
using FruitVision.Api.Infrastructure;
using Microsoft.EntityFrameworkCore;

namespace FruitVision.Api.Ai;

public static class AiInsightsEndpoints
{
    public static void MapAiInsights(this WebApplication app)
    {
        var endpoints = app.MapGroup("/api/v1/ai").RequireAuthorization("Seller").WithTags("Thống kê và hướng dẫn AI");
        endpoints.MapGet("/stats", Stats);
        endpoints.MapGet("/guide", () => Results.Ok(new
        {
            schemaVersion = 1, productCode = "mango", scope = "predicted-mango-only",
            emptyResultMessage = "Không phát hiện xoài đạt ngưỡng",
            executionLocation = "server", maxImageBytes = AiOptions.MaxImageBytes, maxImagePixels = 24_000_000,
            maxVideoBytes = AiOptions.MaxVideoBytes, maxVideoSeconds = 120, maxVideoWidth = 1920,
            maxVideoHeight = 1080, maxVideoFrames = 3600, maxProcessingSeconds = 180, activeJobsPerUser = 1,
            globalQueueCapacity = 4, processorCount = 1,
            steps = new[]
            {
                "Chọn ảnh JPEG/PNG hoặc video MP4 về xoài trong giới hạn dung lượng, kích thước và thời lượng.",
                "Tải tệp từ thiết bị lên máy chủ; mỗi tài khoản chỉ có một tác vụ đang chờ hoặc đang chạy.",
                "Theo dõi tiến độ trực tiếp; khi mất kết nối, tải lại danh sách và chi tiết tác vụ để khôi phục trạng thái.",
                "Đọc tên Xoài (dự đoán) và nhãn giai đoạn trên ảnh minh họa; màu viền không phải thông tin duy nhất. Hủy tác vụ nếu không còn cần xử lý."
            },
            limitations = new[]
            {
                "Chỉ giữ đối tượng được mô hình dự đoán là xoài; bộ lọc có thể bỏ sót hoặc nhận nhầm loài khác.",
                "Chỉ có hai nhãn giai đoạn từ dữ liệu nguồn: Xanh / chưa chín và Chín; độ tin cậy thấp được ghi Chưa xác định. Đây không phải xác nhận độ chín ngoài thực tế.",
                "Không phát hiện xoài đạt ngưỡng không chứng minh ảnh hoặc video không có xoài.",
                "Số xoài thấy đồng thời, số track xác nhận và số lần qua vạch là các đại lượng khác nhau; không mặc định là số quả vật lý duy nhất.",
                "Không suy ra khối lượng, tồn kho, giá thị trường hoặc độ chính xác thực tế từ số đối tượng nhận diện.",
                "Màu vỏ không xác nhận giống xoài, chất lượng bên trong, hư hỏng hoặc an toàn thực phẩm. Không có đầu ra phân loại xoài hư ở tuyến AI hiện tại.",
                "Chỉ dùng cho bản trình diễn phi thương mại. Chất lượng video còn hạn chế; số khung đã xử lý không phải FPS thực tế trên điện thoại.",
                "Phạm vi hiện tại không cung cấp giao dịch, dự báo giá, kết nối IoT hoặc các phân tích chất lượng nâng cao."
            }
        }));
    }

    private sealed record Bucket(DateTime Date, string Status, string MediaType, int Count, long Frames, DateTimeOffset? LastCompletion);
    private sealed record Counts(int Total, int Completed, int Failed, int Queued, int Running, int Cancelled);

    private static Counts Count(IEnumerable<Bucket> rows)
    {
        var values = rows.ToArray();
        int Of(AiJobStatus status) => values.Where(row => row.Status == status.ToString()).Sum(row => row.Count);
        return new(values.Sum(row => row.Count), Of(AiJobStatus.Succeeded), Of(AiJobStatus.Failed),
            Of(AiJobStatus.Queued), Of(AiJobStatus.Running), Of(AiJobStatus.Cancelled));
    }

    private static async Task<IResult> Stats(int? days, HttpContext http, AppDbContext db, CancellationToken ct)
    {
        var selected = days ?? 7;
        if (selected is not (7 or 30 or 90)) return Input.Invalid("days phải là 7, 30 hoặc 90.");
        var asOf = DateTimeOffset.UtcNow;
        var from = new DateTimeOffset(asOf.UtcDateTime.Date.AddDays(1 - selected), TimeSpan.Zero);
        var uid = http.User.UserId();
        // Only scalar GROUP BY aggregates cross the database boundary. Detection/result JSON is
        // never loaded, and frames are not interpreted as unique fruit, kilograms or accuracy.
        // Explicit PostgreSQL timestamp types avoid a provider shaper conversion between the
        // timestamp-without-zone UTC day and nullable timestamp-with-zone completion aggregate.
        var rows = await db.Database.SqlQuery<Bucket>($"""
            SELECT date_trunc('day', "CreatedAt" AT TIME ZONE 'UTC') AS "Date", "Status", "MediaType",
                   COUNT(*)::integer AS "Count", SUM("FramesProcessed"::bigint)::bigint AS "Frames",
                   MAX("CompletedAt") AS "LastCompletion"
            FROM "AiJobs"
            WHERE "UserId" = {uid} AND "CreatedAt" >= {from} AND "CreatedAt" <= {asOf}
            GROUP BY 1, 2, 3
            """).ToListAsync(ct);
        var buckets = Enumerable.Range(0, selected).Select(offset =>
        {
            var date = from.UtcDateTime.Date.AddDays(offset);
            var counts = Count(rows.Where(row => row.Date == date));
            return new { date = date.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture), counts.Total,
                counts.Completed, counts.Failed, counts.Queued, counts.Running, counts.Cancelled };
        }).ToArray();
        return Results.Ok(new
        {
            days = selected, windowStartUtc = from, asOf, timeZone = "UTC", scope = "own-jobs", counts = Count(rows),
            media = new { imageJobs = rows.Where(row => row.MediaType == "image").Sum(row => row.Count),
                videoJobs = rows.Where(row => row.MediaType == "video").Sum(row => row.Count), framesProcessed = rows.Sum(row => row.Frames) },
            jobsByDay = buckets, lastCompletedAt = rows.Where(row => row.Status == nameof(AiJobStatus.Succeeded)).Select(row => row.LastCompletion).Max()
        });
    }
}
