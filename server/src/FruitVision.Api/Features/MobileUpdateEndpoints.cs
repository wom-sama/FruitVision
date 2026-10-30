using FruitVision.Api.Infrastructure;

namespace FruitVision.Api.Features;

public static class MobileUpdateEndpoints
{
    public static void MapMobileUpdates(this WebApplication app)
    {
        var group = app.MapGroup("/api/v1/mobile").WithTags("Cập nhật Android");
        group.MapGet("/update", async (long versionCode, string abi, MobileUpdateService updates, CancellationToken cancellationToken) =>
        {
            if (versionCode <= 0 || !MobileUpdateService.KnownAbi(abi))
                return Results.BadRequest(new { title = "versionCode phải là số nguyên dương; abi phải là arm64-v8a, armeabi-v7a hoặc x86_64." });
            return Results.Ok(await updates.CheckAsync(versionCode, abi, cancellationToken));
        }).AllowAnonymous();
        group.MapGet("/releases/{versionCode:long}/{abi}.apk", async (long versionCode, string abi, MobileUpdateService updates, CancellationToken cancellationToken) =>
        {
            var stream = await updates.OpenDownloadAsync(versionCode, abi, cancellationToken);
            return stream is null ? Results.NotFound() : Results.File(stream, "application/vnd.android.package-archive", enableRangeProcessing: true);
        }).AllowAnonymous();
    }
}
