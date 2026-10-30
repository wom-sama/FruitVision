using Microsoft.EntityFrameworkCore;

namespace FruitVision.Api.Data;

public sealed class BiometricDevice
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public Guid UserId { get; set; }
    public Guid DeviceId { get; set; }
    public string Label { get; set; } = "";
    public string PublicKey { get; set; } = "";
    public DateTimeOffset CreatedAt { get; set; } = DateTimeOffset.UtcNow;
    public DateTimeOffset? LastUsedAt { get; set; }
    public DateTimeOffset? RevokedAt { get; set; }
}

public sealed class BiometricChallenge
{
    public string Hash { get; set; } = "";
    public Guid UserId { get; set; }
    public Guid CredentialId { get; set; }
    public string CredentialPublicKeyHash { get; set; } = "";
    public string SecurityStamp { get; set; } = "";
    public string Payload { get; set; } = "";
    public DateTimeOffset CreatedAt { get; set; } = DateTimeOffset.UtcNow;
    public DateTimeOffset ExpiresAt { get; set; }
    public DateTimeOffset? ConsumedAt { get; set; }
}

public static class BiometricModels
{
    public static void ConfigureModel(ModelBuilder model)
    {
        model.Entity<BiometricDevice>(e =>
        {
            e.ToTable("BiometricDevices");
            e.HasKey(x => x.Id);
            e.HasIndex(x => new { x.UserId, x.DeviceId }).IsUnique();
            e.HasIndex(x => new { x.UserId, x.RevokedAt });
            e.Property(x => x.Label).HasMaxLength(100);
            e.Property(x => x.PublicKey).HasMaxLength(2048);
            e.HasOne<AppUser>().WithMany().HasForeignKey(x => x.UserId).OnDelete(DeleteBehavior.Restrict);
        });
        model.Entity<BiometricChallenge>(e =>
        {
            e.ToTable("BiometricChallenges");
            e.HasKey(x => x.Hash);
            e.Property(x => x.Hash).HasMaxLength(64);
            e.Property(x => x.CredentialPublicKeyHash).HasMaxLength(64);
            e.Property(x => x.SecurityStamp).HasMaxLength(128);
            e.Property(x => x.Payload).HasMaxLength(2048);
            e.HasIndex(x => new { x.CredentialId, x.ConsumedAt });
            e.HasIndex(x => x.ExpiresAt);
            e.HasOne<BiometricDevice>().WithMany().HasForeignKey(x => x.CredentialId).OnDelete(DeleteBehavior.Cascade);
            e.HasOne<AppUser>().WithMany().HasForeignKey(x => x.UserId).OnDelete(DeleteBehavior.Restrict);
        });
        model.Entity<AuthSession>().HasOne<BiometricDevice>().WithMany().HasForeignKey(x => x.BiometricDeviceId).OnDelete(DeleteBehavior.Restrict);
    }
}
