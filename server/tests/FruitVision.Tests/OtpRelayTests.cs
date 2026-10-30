using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using FruitVision.Api.Auth;
using Microsoft.Extensions.Options;
using Xunit;

namespace FruitVision.Tests;

public sealed class OtpRelayTests
{
    private sealed class Relay : HttpMessageHandler, IHttpClientFactory
    {
        public string Response = "{\"ok\":true}";
        public string? Redirect;
        public readonly List<(HttpMethod Method, string Url, string? Body)> Requests = [];
        public HttpClient CreateClient(string name) => new(this, false);
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
        {
            Requests.Add((request.Method, request.RequestUri!.AbsoluteUri, request.Content is null ? null : await request.Content.ReadAsStringAsync(ct)));
            if (Redirect is not null && Requests.Count == 1)
            {
                var redirect = new HttpResponseMessage(HttpStatusCode.Found); redirect.Headers.Location = new Uri(Redirect, UriKind.RelativeOrAbsolute); return redirect;
            }
            return new(HttpStatusCode.OK) { Content = new StringContent(Response) };
        }
    }
    private static readonly string Secret = new('s', 48);
    private static AppsScriptOtpMailer Mailer(Relay relay) => new(relay, Options.Create(new EmailOtpOptions {
        RelayUrl = "https://script.google.com/macros/s/fixture/exec", RelaySecret = Secret
    }));

    [Fact]
    public async Task Signed_exact_protocol_uses_get_for_trusted_redirect_without_resending_body()
    {
        using var relay = new Relay { Redirect = "https://script.googleusercontent.com/macros/echo?user_content_key=fixture" };
        await Mailer(relay).SendAsync("recipient@example.test", "012345", "login", default);
        Assert.Equal(2, relay.Requests.Count); Assert.Equal(HttpMethod.Post, relay.Requests[0].Method); Assert.Equal(HttpMethod.Get, relay.Requests[1].Method); Assert.Null(relay.Requests[1].Body);
        using var envelope = JsonDocument.Parse(relay.Requests[0].Body!);
        var payload = envelope.RootElement.GetProperty("payload").GetString()!;
        var signature = Convert.ToHexString(HMACSHA256.HashData(Encoding.UTF8.GetBytes(Secret), Encoding.UTF8.GetBytes(payload))).ToLowerInvariant();
        Assert.Equal(signature, envelope.RootElement.GetProperty("signature").GetString());
        using var document = JsonDocument.Parse(payload); var body = document.RootElement;
        Assert.Equal(6, body.EnumerateObject().Count()); Assert.Equal("012345", body.GetProperty("code").GetString()); Assert.Equal(10, body.GetProperty("ttlMinutes").GetInt32());
        Assert.True(Guid.TryParse(body.GetProperty("nonce").GetString(), out _)); Assert.InRange(Math.Abs(DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() - body.GetProperty("issuedAt").GetInt64()), 0, 10000);
        Assert.DoesNotContain(Secret, relay.Requests[0].Body!);
    }

    [Theory]
    [InlineData("https://attacker.example/macros/echo")]
    [InlineData("http://script.googleusercontent.com/macros/echo")]
    [InlineData("https://script.googleusercontent.com.evil.example/macros/echo")]
    [InlineData("/relative-output")]
    public async Task Untrusted_redirects_never_receive_any_second_request(string url)
    {
        using var relay = new Relay { Redirect = url };
        await Assert.ThrowsAsync<HttpRequestException>(() => Mailer(relay).SendAsync("recipient@example.test", "123456", "register", default));
        Assert.Single(relay.Requests);
    }

    [Theory]
    [InlineData("{\"ok\":false}")]
    [InlineData("{\"ok\":true,\"other\":1}")]
    [InlineData("[]")]
    public async Task Http_200_does_not_mean_delivery_without_exact_confirmation(string body)
    {
        using var relay = new Relay { Response = body };
        await Assert.ThrowsAsync<HttpRequestException>(() => Mailer(relay).SendAsync("recipient@example.test", "123456", "register", default));
    }
    [Fact]
    public async Task Oversized_response_is_rejected()
    {
        using var relay = new Relay { Response = new string('x', 4097) };
        await Assert.ThrowsAsync<HttpRequestException>(() => Mailer(relay).SendAsync("recipient@example.test", "123456", "register", default));
    }
}
