using FruitVision.Api.Data;
using FruitVision.Api.Infrastructure;
using Microsoft.AspNetCore.Identity;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Xunit;

namespace FruitVision.Tests;

[Collection("Api")]
public sealed class MediaQuotaTests(ApiFixture fixture)
{
    private static readonly string Root = Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "../../../../../.local/quota-tests"));

    [Fact]
    public async Task User_stored_byte_boundary_is_enforced_inside_the_existing_transaction()
    {
        var owner = await Owner();
        using var scope = fixture.Services.CreateScope(); var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
        db.Add(Image(owner, 100)); await db.SaveChangesAsync();
        var configuration = Config(124, await Total(db) + 10000);
        await using var tx = await db.Database.BeginTransactionAsync();
        await LockUser(db, owner);
        await MediaStorageQuota.EnsureAsync(db, owner, 24, Root, configuration, default);
        var rejected = await Assert.ThrowsAsync<MediaQuotaException>(() => MediaStorageQuota.EnsureAsync(db, owner, 25, Root, configuration, default));
        Assert.Equal(409, rejected.Status);
    }

    [Fact]
    public async Task Two_concurrent_admissions_cannot_exceed_the_global_remaining_bytes()
    {
        var first = await Owner(); var second = await Owner(); long baseline;
        using (var scope = fixture.Services.CreateScope()) baseline = await Total(scope.ServiceProvider.GetRequiredService<AppDbContext>());
        var configuration = Config(1000, baseline + 100);
        async Task<int> Admit(Guid owner)
        {
            using var scope = fixture.Services.CreateScope(); var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
            await using var tx = await db.Database.BeginTransactionAsync();
            await LockUser(db, owner);
            try
            {
                await MediaStorageQuota.EnsureAsync(db, owner, 100, Root, configuration, default);
                db.Add(Image(owner, 100)); await db.SaveChangesAsync(); await tx.CommitAsync(); return 201;
            }
            catch (MediaQuotaException error) { return error.Status; }
        }
        var results = await Task.WhenAll(Admit(first), Admit(second));
        Assert.Equal(new[] { 201, 507 }, results.Order().ToArray());
        using var check = fixture.Services.CreateScope(); var context = check.ServiceProvider.GetRequiredService<AppDbContext>();
        Assert.Equal(1, await context.Set<NormalImage>().CountAsync(image => image.OwnerId == first || image.OwnerId == second));
    }

    [Fact]
    public async Task Invalid_limits_insufficient_disk_reserve_and_unavailable_volume_fail_closed()
    {
        var owner = await Owner(); using var scope = fixture.Services.CreateScope(); var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
        var total = await Total(db) + 10000;
        await using var tx = await db.Database.BeginTransactionAsync(); await LockUser(db, owner);
        foreach (var key in new[] { "UserStoredBytes", "TotalStoredBytes", "MinimumFreeDiskBytes" })
        {
            var invalid = Config(1000, total); invalid["MediaLimits:" + key] = "0";
            var error = await Assert.ThrowsAsync<MediaQuotaException>(() => MediaStorageQuota.EnsureAsync(db, owner, 4, Root, invalid, default));
            Assert.Equal(503, error.Status);
        }
        var reserve = Config(1000, total); reserve["MediaLimits:MinimumFreeDiskBytes"] = long.MaxValue.ToString();
        Assert.Equal(507, (await Assert.ThrowsAsync<MediaQuotaException>(() => MediaStorageQuota.EnsureAsync(db, owner, 4, Root, reserve, default))).Status);
        string unavailable;
        if (OperatingSystem.IsWindows())
        {
            var present = DriveInfo.GetDrives().Select(drive => drive.Name).ToHashSet(StringComparer.OrdinalIgnoreCase);
            unavailable = Enumerable.Range('A', 26).Select(letter => ((char)letter) + ":\\").First(root => !present.Contains(root)) + "quota";
        }
        else unavailable = "\0invalid-volume";
        var disk = await Assert.ThrowsAsync<MediaQuotaException>(() => MediaStorageQuota.EnsureAsync(db, owner, 4, unavailable, Config(1000, total), default));
        Assert.Equal(503, disk.Status);
        Assert.DoesNotContain(unavailable, disk.Message);
    }

    private async Task<Guid> Owner()
    {
        using var scope = fixture.Services.CreateScope(); var email = $"quota.{Guid.NewGuid():N}@fruitvision.test";
        var user = new AppUser { Id = Guid.NewGuid(), UserName = email, Email = email, EmailConfirmed = true, DisplayName = "Quota fixture", Role = AccountRole.Consumer, ApprovalStatus = ApprovalState.Approved };
        Assert.True((await scope.ServiceProvider.GetRequiredService<UserManager<AppUser>>().CreateAsync(user, fixture.Password)).Succeeded);
        return user.Id;
    }
    private static NormalImage Image(Guid owner, long bytes) => new() { OwnerId = owner, Width = 1, Height = 1, SizeBytes = bytes, RawSha256 = new string('a', 64), Sha256 = new string('b', 64) };
    private static async Task<long> Total(AppDbContext db) => (await db.Set<NormalImage>().SumAsync(image => (long?)image.SizeBytes) ?? 0) + (await db.Set<SecretAttachment>().SumAsync(image => (long?)image.SizeBytes) ?? 0);
    private static IConfiguration Config(long user, long total) => new ConfigurationBuilder().AddInMemoryCollection(new Dictionary<string, string?> { ["MediaLimits:UserStoredBytes"] = user.ToString(), ["MediaLimits:TotalStoredBytes"] = total.ToString(), ["MediaLimits:MinimumFreeDiskBytes"] = "1" }).Build();
    private static Task<AppUser> LockUser(AppDbContext db, Guid id) => db.Users.FromSqlInterpolated($"SELECT * FROM \"AspNetUsers\" WHERE \"Id\"={id} FOR SHARE").SingleAsync();
}
