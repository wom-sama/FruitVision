using FruitVision.Api.Data;
using FruitVision.Api.Infrastructure;
using Microsoft.EntityFrameworkCore;

namespace FruitVision.Api.Features;

public static class MarketEndpoints
{
    public static void MapMarket(this WebApplication app)
    {
        app.MapGet("/api/v1/market/summary", async (string? region, string? productCode, AppDbContext db, CancellationToken ct) =>
        {
            var filters = await CommunityMarketInput.Filters(db, region, productCode, ct);
            if (filters.Error is not null) return Input.Invalid(filters.Error);
            var normalizedRegion = filters.Region;
            var normalizedProduct = filters.ProductCode;
            // All filtering/aggregation happens in PostgreSQL. Parameters are never SQL fragments.
            var items = await db.Database.SqlQuery<MarketSummaryItem>($"""
                WITH eligible AS (
                    SELECT p."ProductCode", catalog."Name" AS "ProductName",
                        COALESCE(NULLIF(p."Region",''), author."Region") AS "Region",
                        p."AuthorId", p."Purpose", p."EstimatedQuantityKg", p."PriceMinVndPerKg", p."PriceMaxVndPerKg",
                        GREATEST(p."CreatedAt", COALESCE(p."ReviewedAt",p."CreatedAt")) AS "LastUpdated"
                    FROM "Posts" p
                    JOIN "AspNetUsers" author ON author."Id"=p."AuthorId"
                    JOIN "Products" catalog ON catalog."Code"=p."ProductCode"
                    WHERE p."Status"='Published' AND author."IsActive" AND author."ApprovalStatus"='Approved'
                        AND p."Purpose" IN ('Supply','Demand')
                        AND (CAST({normalizedRegion} AS text) IS NULL OR LOWER(COALESCE(NULLIF(p."Region",''),author."Region"))=LOWER({normalizedRegion}))
                        AND (CAST({normalizedProduct} AS text) IS NULL OR p."ProductCode"={normalizedProduct})
                )
                SELECT "ProductCode", "ProductName", "Region",
                    SUM(CASE WHEN "Purpose"='Supply' THEN "EstimatedQuantityKg" ELSE 0 END) AS "SupplyEstimatedKg",
                    SUM(CASE WHEN "Purpose"='Demand' THEN "EstimatedQuantityKg" ELSE 0 END) AS "DemandEstimatedKg",
                    (COUNT(*) FILTER (WHERE "Purpose"='Supply'))::int AS "SupplyPostCount",
                    (COUNT(*) FILTER (WHERE "Purpose"='Demand'))::int AS "DemandPostCount",
                    COUNT(DISTINCT "AuthorId")::int AS "ContributorCount",
                    (percentile_cont(0.5) WITHIN GROUP (ORDER BY ("PriceMinVndPerKg"+"PriceMaxVndPerKg")/2)
                        FILTER (WHERE "Purpose"='Supply' AND "PriceMinVndPerKg">0 AND "PriceMaxVndPerKg">="PriceMinVndPerKg"))::numeric AS "ReferencePriceVndPerKg",
                    MIN("PriceMinVndPerKg") FILTER (WHERE "Purpose"='Supply' AND "PriceMinVndPerKg">0 AND "PriceMaxVndPerKg">="PriceMinVndPerKg") AS "PriceMinVndPerKg",
                    MAX("PriceMaxVndPerKg") FILTER (WHERE "Purpose"='Supply' AND "PriceMinVndPerKg">0 AND "PriceMaxVndPerKg">="PriceMinVndPerKg") AS "PriceMaxVndPerKg",
                    (COUNT(*) FILTER (WHERE "Purpose"='Supply' AND "PriceMinVndPerKg">0 AND "PriceMaxVndPerKg">="PriceMinVndPerKg"))::int AS "PriceSampleCount",
                    MAX("LastUpdated") AS "LastUpdated"
                FROM eligible
                GROUP BY "ProductCode", "ProductName", "Region"
                ORDER BY "Region", "ProductCode"
                LIMIT 501
                """).ToListAsync(ct);
            if (items.Count > 500) return Input.Invalid("Có quá nhiều khu vực/nông sản; hãy chọn bộ lọc cụ thể hơn.");
            return Results.Ok(new
            {
                region = normalizedRegion, productCode = normalizedProduct, asOf = DateTimeOffset.UtcNow,
                source = "published-user-asking-prices", isForecast = false, items,
                limitations = new[]
                {
                    "Lượng cung/cầu là dự báo do người dùng đăng, không phải tồn kho thực, đơn hàng hoặc cam kết giao hàng.",
                    "Giá tham chiếu chỉ là trung vị điểm giữa khoảng giá chào bán của các bài cung công khai; không gồm giá hỏi mua, không phải giá giao dịch, giá thị trường chính thức hay dự đoán AI.",
                    "Mẫu tự khai có thể ít, cũ hoặc thiên lệch. Không có khoảng giá hợp lệ thì giá được để trống; không tạo giá giả.",
                    "Mỗi người có thể đăng nhiều bài; tổng lượng không bảo đảm đã loại trừ cùng một lô hàng."
                }
            });
        });
    }
}

public sealed class MarketSummaryItem
{
    public string ProductCode { get; set; } = "";
    public string ProductName { get; set; } = "";
    public string Region { get; set; } = "";
    public decimal SupplyEstimatedKg { get; set; }
    public decimal DemandEstimatedKg { get; set; }
    public int SupplyPostCount { get; set; }
    public int DemandPostCount { get; set; }
    public int ContributorCount { get; set; }
    public decimal? ReferencePriceVndPerKg { get; set; }
    public decimal? PriceMinVndPerKg { get; set; }
    public decimal? PriceMaxVndPerKg { get; set; }
    public int PriceSampleCount { get; set; }
    public DateTimeOffset LastUpdated { get; set; }
}

internal static class CommunityMarketInput
{
    internal sealed record FilterValues(string? Region, string? ProductCode, string? Error);
    internal static async Task<FilterValues> Filters(AppDbContext db, string? region, string? productCode, CancellationToken ct)
    {
        if (region is not null)
        {
            if (!Input.Safe(region) || Input.Text(region).Length is < 2 or > 120)
                return new(null, null, "Khu vực phải từ 2 đến 120 ký tự hợp lệ.");
            region = Input.Text(region);
        }
        if (productCode is not null)
        {
            if (!Input.Safe(productCode) || Input.Text(productCode).Length is < 1 or > 40)
                return new(null, null, "Mã nông sản không hợp lệ.");
            productCode = Input.Text(productCode);
            if (!await db.Products.AnyAsync(p => p.Code == productCode, ct)) return new(null, null, "Nông sản không tồn tại.");
        }
        return new(region, productCode, null);
    }
}
