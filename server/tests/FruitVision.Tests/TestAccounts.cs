using FruitVision.Api.Data;
using Microsoft.AspNetCore.Identity;
using Microsoft.Extensions.DependencyInjection;
using Xunit;

namespace FruitVision.Tests;

public sealed record TestAccount(Guid Id, string Email, Guid? BranchId);

// Test data only. Authentication and authorization still execute through the real API.
public static class TestAccounts
{
    public static async Task<TestAccount> CreateAsync(IServiceProvider services, string password,
        string role, bool approve = true, string displayName = "Fixture")
    {
        using var scope = services.CreateScope();
        var manager = scope.ServiceProvider.GetRequiredService<UserManager<AppUser>>();
        var email = $"fixture-{Guid.NewGuid():N}@example.test";
        var user = new AppUser
        {
            Id = Guid.NewGuid(), UserName = email, Email = email, EmailConfirmed = true,
            DisplayName = displayName, Region = "Đồng Tháp", CountryCode = "VN", ProvinceCode = "79",
            Role = Enum.Parse<AccountRole>(role),
            ApprovalStatus = approve ? ApprovalState.Approved : ApprovalState.Pending,
            IsActive = true, LockoutEnabled = true
        };
        var created = await manager.CreateAsync(user, password);
        Assert.True(created.Succeeded, string.Join(", ", created.Errors.Select(error => error.Code)));
        Guid? branchId = null;
        if (user.Role is AccountRole.Producer or AccountRole.Trader)
        {
            var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
            var branch = new SellerBranch
            {
                OwnerId = user.Id, Name = "Fixture approved branch", CountryCode = "VN", ProvinceCode = "79",
                CountryName = "Việt Nam", ProvinceName = "Đồng Tháp", Region = "Đồng Tháp",
                Street = "123 Fixture Road", Phone = "0901234567", Status = "Approved",
                ReviewedAt = DateTimeOffset.UtcNow, ReviewReason = "Test fixture; moderation covered separately"
            };
            db.Add(branch);
            await db.SaveChangesAsync();
            branchId = branch.Id;
        }
        return new(user.Id, email, branchId);
    }
}
