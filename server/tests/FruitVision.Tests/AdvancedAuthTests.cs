using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Security.Cryptography;
using System.Text.Json;
using Microsoft.AspNetCore.Hosting;
using Microsoft.Extensions.Configuration;
using Xunit;

namespace FruitVision.Tests;

[Collection("Api")]
public class AdvancedAuthTests(ApiFixture fixture)
{
    [Fact]
    public async Task Mfa_requires_totp_consumes_challenge_once_and_revokes_pre_mfa_sessions()
    {
        using var c=fixture.CreateClient();
        var account=await TestAccounts.CreateAsync(fixture.Services,fixture.Password,"Consumer",displayName:"MFA test");var email=account.Email;
        var login=await (await c.PostAsJsonAsync("/api/v1/auth/login",new{email,password=fixture.Password})).Content.ReadFromJsonAsync<JsonElement>();
        c.DefaultRequestHeaders.Authorization=new AuthenticationHeaderValue("Bearer",login.GetProperty("accessToken").GetString());
        var setup=await (await c.PostAsJsonAsync("/api/v1/auth/mfa/setup",new{password=fixture.Password})).Content.ReadFromJsonAsync<JsonElement>();
        var key=setup.GetProperty("sharedKey").GetString()!;
        Assert.DoesNotContain(key,(await c.GetStringAsync("/api/v1/auth/me")));
        var enabled=await c.PostAsJsonAsync("/api/v1/auth/mfa/enable",new{code=Totp(key)});Assert.Equal(HttpStatusCode.OK,enabled.StatusCode);
        Assert.Equal(HttpStatusCode.Unauthorized,(await c.GetAsync("/api/v1/auth/me")).StatusCode);
        c.DefaultRequestHeaders.Authorization=null;
        var challenge=await (await c.PostAsJsonAsync("/api/v1/auth/login",new{email,password=fixture.Password})).Content.ReadFromJsonAsync<JsonElement>();
        Assert.True(challenge.GetProperty("requiresTwoFactor").GetBoolean());
        Assert.False(challenge.TryGetProperty("accessToken",out _));
        var challengeToken=challenge.GetProperty("challengeToken").GetString();
        var second=await c.PostAsJsonAsync("/api/v1/auth/mfa/login",new{challengeToken,code=Totp(key)});second.EnsureSuccessStatusCode();
        var session=await second.Content.ReadFromJsonAsync<JsonElement>();Assert.True(session.TryGetProperty("accessToken",out _));
        Assert.Equal(HttpStatusCode.Unauthorized,(await c.PostAsJsonAsync("/api/v1/auth/mfa/login",new{challengeToken,code=Totp(key)})).StatusCode);
    }

    [Fact]
    public async Task Five_bad_passwords_lock_account_and_do_not_leak_password_or_tokens()
    {
        using var c=fixture.CreateClient();
        var account=await TestAccounts.CreateAsync(fixture.Services,fixture.Password,"Consumer",displayName:"Lockout test");var email=account.Email;
        for(var i=0;i<5;i++){
            var response=await c.PostAsJsonAsync("/api/v1/auth/login",new{email,password="Wrong-password-123!"});
            Assert.Equal(HttpStatusCode.Unauthorized,response.StatusCode);
            var body=await response.Content.ReadAsStringAsync();Assert.DoesNotContain(fixture.Password,body);Assert.DoesNotContain("accessToken",body);
        }
        Assert.Equal(HttpStatusCode.Unauthorized,(await c.PostAsJsonAsync("/api/v1/auth/login",new{email,password=fixture.Password})).StatusCode);
    }

    [Fact]
    public async Task Auth_rate_limit_returns_429_and_retry_after_instead_of_queueing()
    {
        await using var limited=fixture.WithWebHostBuilder(b=>b.ConfigureAppConfiguration((_,c)=>c.AddInMemoryCollection(new Dictionary<string,string?>{{"Limits:AuthPerMinute","2"}})));
        using var c=limited.CreateClient();
        for(var i=0;i<2;i++)Assert.Equal(HttpStatusCode.Unauthorized,(await c.PostAsJsonAsync("/api/v1/auth/login",new{email="absent@example.test",password="Wrong-password-123!"})).StatusCode);
        var blocked=await c.PostAsJsonAsync("/api/v1/auth/login",new{email="absent@example.test",password="Wrong-password-123!"});
        Assert.Equal(HttpStatusCode.TooManyRequests,blocked.StatusCode);Assert.NotNull(blocked.Headers.RetryAfter);
    }

    // Independent test-only RFC6238 generator; production uses ASP.NET Identity's provider.
    private static string Totp(string key)
    {
        const string alphabet="ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";
        var bytes=new List<byte>();var buffer=0;var bits=0;
        foreach(var ch in key.ToUpperInvariant().TrimEnd('=')){buffer=(buffer<<5)|alphabet.IndexOf(ch);bits+=5;if(bits>=8){bits-=8;bytes.Add((byte)(buffer>>bits));}}
        var counter=BitConverter.GetBytes(DateTimeOffset.UtcNow.ToUnixTimeSeconds()/30);if(BitConverter.IsLittleEndian)Array.Reverse(counter);
        var h=HMACSHA1.HashData(bytes.ToArray(),counter);var offset=h[^1]&15;
        var number=((h[offset]&127)<<24)|(h[offset+1]<<16)|(h[offset+2]<<8)|h[offset+3];
        return (number%1_000_000).ToString("D6");
    }
}
