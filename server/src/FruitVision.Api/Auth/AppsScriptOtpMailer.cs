using System.Net;
using System.Net.Http.Json;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using Microsoft.Extensions.Options;

namespace FruitVision.Api.Auth;

/// <summary>Transport compatible with the existing HUTECH sender; challenges belong only to FruitVision.</summary>
public sealed class AppsScriptOtpMailer(IHttpClientFactory clients, IOptions<EmailOtpOptions> options) : IEmailOtpMailer
{
    public const string ClientName = "EmailOtpRelay";
    public bool IsReady => TrustedRelay(options.Value.RelayUrl) && options.Value.RelaySecret.Length >= 32;
    private static bool TrustedRelay(string value) => Uri.TryCreate(value, UriKind.Absolute, out var u) &&
        u.Scheme == "https" && u.Host == "script.google.com" && u.IsDefaultPort && u.UserInfo.Length == 0 &&
        u.Query.Length == 0 && u.Fragment.Length == 0 && Regex.IsMatch(u.AbsolutePath, "^/macros/s/[A-Za-z0-9_-]+/exec$", RegexOptions.CultureInvariant);
    private static bool TrustedOutput(Uri u) => u.IsAbsoluteUri && u.Scheme == "https" && u.Host == "script.googleusercontent.com" &&
        u.IsDefaultPort && u.UserInfo.Length == 0 && u.Fragment.Length == 0 && u.AbsolutePath.StartsWith("/macros/", StringComparison.Ordinal);

    public async Task SendAsync(string recipient, string code, string purpose, CancellationToken cancellationToken)
    {
        if (!IsReady || !System.Net.Mail.MailAddress.TryCreate(recipient, out var address) || address.Address != recipient ||
            recipient.Any(char.IsControl) || !Regex.IsMatch(code, "^[0-9]{6}$", RegexOptions.CultureInvariant) || purpose is not ("register" or "login" or "face_login"))
            throw new InvalidOperationException("OTP delivery is unavailable.");
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken); deadline.CancelAfter(TimeSpan.FromSeconds(15));
        var payload = JsonSerializer.Serialize(new { to = recipient, code, purpose, issuedAt = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(), nonce = Guid.NewGuid().ToString("D"), ttlMinutes = 10 });
        var signature = Convert.ToHexString(HMACSHA256.HashData(Encoding.UTF8.GetBytes(options.Value.RelaySecret), Encoding.UTF8.GetBytes(payload))).ToLowerInvariant();
        using var client = clients.CreateClient(ClientName);
        using var post = new HttpRequestMessage(HttpMethod.Post, options.Value.RelayUrl) { Content = JsonContent.Create(new { payload, signature }) };
        post.Headers.Accept.ParseAdd("application/json");
        using var first = await client.SendAsync(post, HttpCompletionOption.ResponseHeadersRead, deadline.Token);
        if (first.StatusCode is HttpStatusCode.Found or HttpStatusCode.SeeOther)
        {
            var location = first.Headers.Location;
            if (location is null || !TrustedOutput(location)) throw new HttpRequestException("OTP relay redirect rejected.");
            using var get = new HttpRequestMessage(HttpMethod.Get, location); get.Headers.Accept.ParseAdd("application/json");
            using var second = await client.SendAsync(get, HttpCompletionOption.ResponseHeadersRead, deadline.Token);
            await Confirm(second, deadline.Token);
        }
        else await Confirm(first, deadline.Token);
    }
    private static async Task Confirm(HttpResponseMessage response, CancellationToken ct)
    {
        response.EnsureSuccessStatusCode();
        if (response.Content.Headers.ContentLength is > 4096) throw new HttpRequestException("OTP relay response too large.");
        await using var stream = await response.Content.ReadAsStreamAsync(ct);
        using var body = new MemoryStream(); var buffer = new byte[1024]; int size;
        while ((size = await stream.ReadAsync(buffer, ct)) != 0)
        {
            if (body.Length + size > 4096) throw new HttpRequestException("OTP relay response too large.");
            body.Write(buffer, 0, size);
        }
        using var json = JsonDocument.Parse(body.ToArray(), new JsonDocumentOptions { MaxDepth = 4 });
        var root = json.RootElement;
        if (root.ValueKind != JsonValueKind.Object || root.EnumerateObject().Count() != 1 || !root.TryGetProperty("ok", out var ok) || ok.ValueKind != JsonValueKind.True)
            throw new HttpRequestException("OTP relay did not confirm delivery.");
    }
}
