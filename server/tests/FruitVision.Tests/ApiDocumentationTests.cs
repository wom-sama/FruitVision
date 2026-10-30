using System.Net;
using System.Text.Json;
using Xunit;

namespace FruitVision.Tests;

[Collection("Api")]
public class ApiDocumentationTests(ApiFixture fixture)
{
    [Fact]
    public async Task Swagger_and_openapi_are_public_and_registration_has_no_client_role()
    {
        using var c=fixture.CreateClient();
        var html=await c.GetAsync("/v1/index.html");Assert.Equal(HttpStatusCode.OK,html.StatusCode);
        using var doc=JsonDocument.Parse(await c.GetStringAsync("/openapi/v1.json"));var root=doc.RootElement;
        var schemas=root.GetProperty("components").GetProperty("schemas");
        var registration=schemas.GetProperty("RegisterRequest").GetProperty("properties");
        Assert.False(registration.TryGetProperty("role",out _));
        Assert.False(registration.TryGetProperty("approvalStatus",out _));
        Assert.False(registration.TryGetProperty("region",out _));
        Assert.True(registration.TryGetProperty("countryCode",out _));
        Assert.True(registration.TryGetProperty("provinceCode",out _));
        var approval=schemas.GetProperty("ApprovalState");
        Assert.Equal("string",approval.GetProperty("type").GetString());
        Assert.Equal(new[]{"Pending","NeedsInformation","Approved","Rejected"},approval.GetProperty("enum").EnumerateArray().Select(x=>x.GetString()));
        Assert.False(root.GetProperty("paths").GetProperty("/api/v1/auth/login").GetProperty("post").TryGetProperty("security",out _));
        Assert.True(root.GetProperty("paths").GetProperty("/api/v1/auth/me").GetProperty("get").GetProperty("security").GetArrayLength()>0);
    }
}
