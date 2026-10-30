using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text.Json;
using FruitVision.Api.Data;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
using Xunit;

namespace FruitVision.Tests;

[Collection("Api")]
public sealed class BusinessBranchTests(ApiFixture fixture)
{
    [Fact]
    public async Task New_business_posts_require_explicit_owned_approved_branch_and_use_its_region()
    {
        using var c = fixture.CreateClient();
        using var login = await c.PostAsJsonAsync("/api/v1/auth/login", new { email = "producer@fruitvision.test", password = fixture.Password });
        var session = await login.Content.ReadFromJsonAsync<JsonElement>();
        c.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", session.GetProperty("accessToken").GetString());
        var userId = session.GetProperty("user").GetProperty("id").GetGuid();
        using var missing = await c.PostAsJsonAsync("/api/v1/posts", new { title = "Supply post", body = "Actual supply information", productCode = "mango", estimatedQuantityKg = 10 });
        Assert.Equal(HttpStatusCode.BadRequest, missing.StatusCode);
        var branch = new SellerBranch { OwnerId = userId, Name = "Fixture approved branch", CountryCode = "VN", ProvinceCode = "79", CountryName = "Việt Nam", ProvinceName = "TP Hồ Chí Minh", Region = "TP Hồ Chí Minh, Việt Nam", Street = "Fixture street", Phone = "0901234567", Status = "Pending" };
        using (var scope = fixture.Services.CreateScope()) { var db = scope.ServiceProvider.GetRequiredService<AppDbContext>(); db.Add(branch); await db.SaveChangesAsync(); }
        object Body(Guid id) => new { title = "Supply post", body = "Actual supply information", productCode = "mango", estimatedQuantityKg = 10, branchId = id };
        using var pending = await c.PostAsJsonAsync("/api/v1/posts", Body(branch.Id)); Assert.Equal(HttpStatusCode.Conflict, pending.StatusCode);
        using var foreign = await c.PostAsJsonAsync("/api/v1/posts", Body(Guid.NewGuid())); Assert.Equal(HttpStatusCode.Conflict, foreign.StatusCode);
        using (var scope = fixture.Services.CreateScope()) await scope.ServiceProvider.GetRequiredService<AppDbContext>().Set<SellerBranch>().Where(b => b.Id == branch.Id).ExecuteUpdateAsync(s => s.SetProperty(b => b.Status, "Approved"));
        using var accepted = await c.PostAsJsonAsync("/api/v1/posts", Body(branch.Id)); Assert.Equal(HttpStatusCode.Created, accepted.StatusCode);
        var post = await accepted.Content.ReadFromJsonAsync<JsonElement>(); Assert.Equal(branch.Region, post.GetProperty("region").GetString()); Assert.Equal(branch.Id, post.GetProperty("branchId").GetGuid());
        using var arbitraryRegion = await c.PostAsJsonAsync("/api/v1/posts", new { title = "Supply post", body = "Actual supply information", productCode = "mango", estimatedQuantityKg = 10, branchId = branch.Id, region = "Forged trusted region" }); Assert.Equal(HttpStatusCode.BadRequest, arbitraryRegion.StatusCode);
    }
}
