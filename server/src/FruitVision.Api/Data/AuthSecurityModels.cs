using Microsoft.EntityFrameworkCore;

namespace FruitVision.Api.Data;

public sealed class EmailOtpChallenge
{
    public string Hash { get; set; } = "";
    public Guid UserId { get; set; }
    public string SecurityStamp { get; set; } = "";
    public string Recipient { get; set; } = "";
    public string Purpose { get; set; } = "login";
    public string CodeHash { get; set; } = "";
    public int Attempts { get; set; }
    public int SendCount { get; set; } = 1;
    public DateTimeOffset SentAt { get; set; } = DateTimeOffset.UtcNow;
    public DateTimeOffset ExpiresAt { get; set; }
    public bool Consumed { get; set; }
}

public static class AuthSecurityModels
{
    public static void ConfigureModel(ModelBuilder model)
    {
        model.Entity<EmailOtpChallenge>(e =>
        {
            e.ToTable("EmailOtpChallenges"); e.HasKey(x => x.Hash);
            e.Property(x => x.Hash).HasMaxLength(64);
            e.Property(x => x.SecurityStamp).HasMaxLength(128);
            e.Property(x => x.Recipient).HasMaxLength(254);
            e.Property(x => x.Purpose).HasMaxLength(16);
            e.Property(x => x.CodeHash).HasMaxLength(64);
            e.HasIndex(x => new { x.UserId, x.SentAt });
            e.HasOne<AppUser>().WithMany().HasForeignKey(x => x.UserId).OnDelete(DeleteBehavior.Cascade);
        });
    }
}
