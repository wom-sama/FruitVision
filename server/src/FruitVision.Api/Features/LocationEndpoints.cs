using FruitVision.Api.Infrastructure;

namespace FruitVision.Api.Features;

public static class LocationEndpoints
{
    public static void MapLocations(this WebApplication app)
    {
        var routes = app.MapGroup("/api/v1/locations").WithTags("Địa điểm");
        routes.MapGet("/countries", async (LocationDirectory directory, CancellationToken cancellationToken) =>
        {
            try { return Results.Ok(await directory.GetCountriesAsync(cancellationToken)); }
            catch (LocationDirectoryUnavailableException) { return Unavailable(); }
        }).WithSummary("Quốc gia theo nguồn dữ liệu, nhãn tiếng Việt và độ mới cache");
        routes.MapGet("/provinces", async (string? country, LocationDirectory directory, CancellationToken cancellationToken) =>
        {
            try { return Results.Ok(await directory.GetProvincesAsync(country, cancellationToken)); }
            catch (LocationSelectionException error) { return Input.Invalid(error.Message); }
            catch (LocationDirectoryUnavailableException) { return Unavailable(); }
        }).WithSummary("Tỉnh/thành của quốc gia; Việt Nam chỉ dùng nguồn v2/34 tỉnh");
    }
    private static IResult Unavailable() => Results.Problem(statusCode: 503,
        title: "Danh mục địa điểm chưa sẵn sàng.", detail: "Không có dữ liệu đã xác minh còn hạn; vui lòng thử lại sau.");
}
