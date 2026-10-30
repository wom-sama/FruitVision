namespace FruitVision.Api.Auth;

public sealed class EmailOtpOptions
{
    public string RelayUrl { get; set; } = "";
    public string RelaySecret { get; set; } = "";
    public string HashKey { get; set; } = "";
    public bool RequireOnPasswordLogin { get; set; } = true;
    // Operator-only mappings for the four synthetic demo identities; never supplied by callers.
    public Dictionary<string, string> DemoRecipients { get; set; } = new(StringComparer.OrdinalIgnoreCase);
}

public interface IEmailOtpMailer
{
    bool IsReady { get; }
    Task SendAsync(string recipient, string code, string purpose, CancellationToken cancellationToken);
}
