using Microsoft.EntityFrameworkCore;

namespace FruitVision.Api.Data;

public sealed class SecretDevice
{
    public Guid DeviceId { get; set; }
    public Guid UserId { get; set; }
    public int Version { get; set; }
    public string Label { get; set; } = "";
    public string EncryptionPublicKey { get; set; } = "";
    public string SigningPublicKey { get; set; } = "";
    public DateTimeOffset CreatedAt { get; set; } = DateTimeOffset.UtcNow;
    public DateTimeOffset? RevokedAt { get; set; }
}

public sealed class SecretConversation
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public Guid DirectConversationId { get; set; }
    public Conversation DirectConversation { get; set; } = null!;
    public Guid FirstUserId { get; set; }
    public AppUser FirstUser { get; set; } = null!;
    public Guid SecondUserId { get; set; }
    public AppUser SecondUser { get; set; } = null!;
    public long NextSequence { get; set; }
    public DateTimeOffset CreatedAt { get; set; } = DateTimeOffset.UtcNow;
    public DateTimeOffset LastActivityAt { get; set; } = DateTimeOffset.UtcNow;
}

public sealed class SecretMessage
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public Guid ConversationId { get; set; }
    public Guid SenderUserId { get; set; }
    public Guid SenderDeviceId { get; set; }
    public int SenderKeyVersion { get; set; }
    public Guid ClientMessageId { get; set; }
    public long Sequence { get; set; }
    public string RequestHash { get; set; } = "";
    public DateTimeOffset CreatedAt { get; set; } = DateTimeOffset.UtcNow;
}

public sealed class SecretEnvelope
{
    public Guid MessageId { get; set; }
    public Guid RecipientUserId { get; set; }
    public Guid RecipientDeviceId { get; set; }
    public int RecipientKeyVersion { get; set; }
    public string CiphertextBase64 { get; set; } = "";
}

public sealed class SecretAttachment
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public Guid ConversationId { get; set; }
    public Guid UploaderUserId { get; set; }
    public Guid SenderDeviceId { get; set; }
    public Guid RecipientDeviceId { get; set; }
    public int SenderKeyVersion { get; set; }
    public int RecipientKeyVersion { get; set; }
    public long SizeBytes { get; set; }
    public string Sha256 { get; set; } = "";
    public DateTimeOffset CreatedAt { get; set; } = DateTimeOffset.UtcNow;
}

public static class SecretMessagingModels
{
    public static void ConfigureModel(ModelBuilder model)
    {
        model.Entity<SecretDevice>(e =>
        {
            e.ToTable("SecretDevices", t => t.HasCheckConstraint("CK_SecretDevice_Version", "\"Version\" >= 1"));
            e.HasKey(x => x.DeviceId);
            e.Property(x => x.Label).HasMaxLength(100);
            e.Property(x => x.EncryptionPublicKey).HasMaxLength(44);
            e.Property(x => x.SigningPublicKey).HasMaxLength(44);
            e.HasIndex(x => x.UserId).IsUnique().HasFilter("\"RevokedAt\" IS NULL");
            e.HasIndex(x => new { x.UserId, x.Version }).IsUnique();
            e.HasOne<AppUser>().WithMany().HasForeignKey(x => x.UserId).OnDelete(DeleteBehavior.Restrict);
        });
        model.Entity<SecretConversation>(e =>
        {
            e.ToTable("SecretConversations", t =>
            {
                t.HasCheckConstraint("CK_SecretConversation_Pair", "\"FirstUserId\" <> \"SecondUserId\"");
                t.HasCheckConstraint("CK_SecretConversation_Sequence", "\"NextSequence\" >= 0");
            });
            e.HasKey(x => x.Id);
            e.HasIndex(x => x.DirectConversationId).IsUnique();
            e.HasIndex(x => new { x.FirstUserId, x.LastActivityAt, x.Id });
            e.HasIndex(x => new { x.SecondUserId, x.LastActivityAt, x.Id });
            e.HasOne(x => x.DirectConversation).WithMany().HasForeignKey(x => x.DirectConversationId).OnDelete(DeleteBehavior.Restrict);
            e.HasOne(x => x.FirstUser).WithMany().HasForeignKey(x => x.FirstUserId).OnDelete(DeleteBehavior.Restrict);
            e.HasOne(x => x.SecondUser).WithMany().HasForeignKey(x => x.SecondUserId).OnDelete(DeleteBehavior.Restrict);
        });
        model.Entity<SecretMessage>(e =>
        {
            e.ToTable("SecretMessages", t => t.HasCheckConstraint("CK_SecretMessage_Sequence", "\"Sequence\" >= 1"));
            e.HasKey(x => x.Id);
            e.Property(x => x.RequestHash).HasMaxLength(64);
            e.HasIndex(x => new { x.ConversationId, x.SenderUserId, x.ClientMessageId }).IsUnique();
            e.HasIndex(x => new { x.ConversationId, x.Sequence }).IsUnique();
            e.HasOne<SecretConversation>().WithMany().HasForeignKey(x => x.ConversationId).OnDelete(DeleteBehavior.Restrict);
            e.HasOne<AppUser>().WithMany().HasForeignKey(x => x.SenderUserId).OnDelete(DeleteBehavior.Restrict);
            e.HasOne<SecretDevice>().WithMany().HasForeignKey(x => x.SenderDeviceId).OnDelete(DeleteBehavior.Restrict);
        });
        model.Entity<SecretEnvelope>(e =>
        {
            e.ToTable("SecretEnvelopes");
            e.HasKey(x => new { x.MessageId, x.RecipientDeviceId });
            e.Property(x => x.CiphertextBase64).HasMaxLength(21848);
            e.HasIndex(x => new { x.RecipientUserId, x.RecipientDeviceId, x.MessageId });
            e.HasOne<SecretMessage>().WithMany().HasForeignKey(x => x.MessageId).OnDelete(DeleteBehavior.Cascade);
            e.HasOne<AppUser>().WithMany().HasForeignKey(x => x.RecipientUserId).OnDelete(DeleteBehavior.Restrict);
            e.HasOne<SecretDevice>().WithMany().HasForeignKey(x => x.RecipientDeviceId).OnDelete(DeleteBehavior.Restrict);
        });
        model.Entity<SecretAttachment>(e =>
        {
            e.ToTable("SecretAttachments", t => t.HasCheckConstraint("CK_SecretAttachment_Size", "\"SizeBytes\" > 0 AND \"SizeBytes\" <= 5308416"));
            e.HasKey(x => x.Id);
            e.Property(x => x.Sha256).HasMaxLength(64);
            e.HasIndex(x => new { x.ConversationId, x.CreatedAt });
            e.HasOne<SecretConversation>().WithMany().HasForeignKey(x => x.ConversationId).OnDelete(DeleteBehavior.Restrict);
            e.HasOne<AppUser>().WithMany().HasForeignKey(x => x.UploaderUserId).OnDelete(DeleteBehavior.Restrict);
            e.HasOne<SecretDevice>().WithMany().HasForeignKey(x => x.SenderDeviceId).OnDelete(DeleteBehavior.Restrict);
            e.HasOne<SecretDevice>().WithMany().HasForeignKey(x => x.RecipientDeviceId).OnDelete(DeleteBehavior.Restrict);
        });
    }
}
