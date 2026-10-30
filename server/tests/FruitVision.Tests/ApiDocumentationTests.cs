using System.Net;
using System.Text.Json;
using Xunit;

namespace FruitVision.Tests;

[Collection("Api")]
public class ApiDocumentationTests(ApiFixture fixture)
{
    [Fact]
    public async Task Swagger_and_openapi_are_public_and_enum_contracts_match_registration()
    {
        using var c=fixture.CreateClient();
        var html=await c.GetAsync("/v1/index.html");Assert.Equal(HttpStatusCode.OK,html.StatusCode);
        using var doc=JsonDocument.Parse(await c.GetStringAsync("/openapi/v1.json"));var root=doc.RootElement;
        var role=root.GetProperty("components").GetProperty("schemas").GetProperty("BusinessRole");
        Assert.Equal("string",role.GetProperty("type").GetString());
        Assert.Equal(new[]{"Producer","Trader","Consumer"},role.GetProperty("enum").EnumerateArray().Select(x=>x.GetString()));
        Assert.False(root.GetProperty("paths").GetProperty("/api/v1/auth/login").GetProperty("post").TryGetProperty("security",out _));
        Assert.True(root.GetProperty("paths").GetProperty("/api/v1/auth/me").GetProperty("get").GetProperty("security").GetArrayLength()>0);
    }
}
