using System.Security.Cryptography;
using System.Text.Json;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.Extensions.Configuration;
using Npgsql;
using Xunit;

namespace FruitVision.Tests;

[CollectionDefinition("Api",DisableParallelization=true)]
public class ApiCollection : ICollectionFixture<ApiFixture> { }

public sealed class ApiFixture : WebApplicationFactory<Program>,IAsyncLifetime
{
    public string Password {get;}="FvTest9!"+Convert.ToHexString(RandomNumberGenerator.GetBytes(16));
    private readonly string database="fv_test_"+Guid.NewGuid().ToString("N");
    private string? adminConnection;
    protected override void ConfigureWebHost(IWebHostBuilder builder)
    {
        var root=Environment.GetEnvironmentVariable("FRUITVISION_TEST_CONFIG")??Path.GetFullPath(Path.Combine(AppContext.BaseDirectory,"../../../../../.local/runtime.json"));
        using var doc=JsonDocument.Parse(File.ReadAllText(root));
        adminConnection=doc.RootElement.GetProperty("LocalAdminConnection").GetString()!;
        var c=new NpgsqlConnectionStringBuilder(adminConnection){Database=database};
        builder.UseEnvironment("Testing").ConfigureAppConfiguration((_,config)=>config.AddInMemoryCollection(new Dictionary<string,string?>{
            ["ConnectionStrings:Database"]=c.ConnectionString,["Database:AutoMigrate"]="true",
            ["Demo:Enabled"]="true",["Demo:Password"]=Password,
            ["Limits:AuthPerMinute"]="500",["Limits:RequestsPerMinute"]="1000"
        }));
    }
    public Task InitializeAsync(){using var c=CreateClient();return Task.CompletedTask;}
    public new async Task DisposeAsync()
    {
        await base.DisposeAsync();NpgsqlConnection.ClearAllPools();
        if(adminConnection is null)return;
        await using var c=new NpgsqlConnection(adminConnection);await c.OpenAsync();
        if(!database.StartsWith("fv_test_")||database.Length!=40)throw new InvalidOperationException("Test database guard failed.");
        await using var command=new NpgsqlCommand($"DROP DATABASE IF EXISTS \"{database}\" WITH (FORCE)",c);await command.ExecuteNonQueryAsync();
    }
}
