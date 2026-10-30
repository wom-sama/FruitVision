using Microsoft.EntityFrameworkCore;

namespace FruitVision.Api.Data;

public sealed class NormalImage
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public Guid OwnerId { get; set; }
    public string Purpose { get; set; } = "Article";
    public Guid? ConversationId { get; set; }
    public string ContentType { get; set; } = "image/jpeg";
    public int Width { get; set; }
    public int Height { get; set; }
    public long SizeBytes { get; set; }
    public string RawSha256 { get; set; } = "";
    public string Sha256 { get; set; } = "";
    public DateTimeOffset CreatedAt { get; set; } = DateTimeOffset.UtcNow;
    public DateTimeOffset? ConsumedAt { get; set; }
}

public static class NormalMediaModels
{
    public static void ConfigureModel(ModelBuilder builder)
    {
        builder.Entity<NormalImage>(entity =>
        {
            entity.ToTable("NormalImages", table =>
            {
                table.HasCheckConstraint("CK_NormalImage_Purpose", "(\"Purpose\"='Article' AND \"ConversationId\" IS NULL) OR (\"Purpose\"='Chat' AND \"ConversationId\" IS NOT NULL)");
                table.HasCheckConstraint("CK_NormalImage_Format", "\"ContentType\"='image/jpeg' AND \"Width\" BETWEEN 1 AND 2048 AND \"Height\" BETWEEN 1 AND 2048 AND \"SizeBytes\" BETWEEN 4 AND 5242880");
            });
            entity.Property(i => i.Purpose).HasMaxLength(12);
            entity.Property(i => i.ContentType).HasMaxLength(20);
            entity.Property(i => i.RawSha256).HasMaxLength(64);
            entity.Property(i => i.Sha256).HasMaxLength(64);
            entity.HasOne<AppUser>().WithMany().HasForeignKey(i => i.OwnerId).OnDelete(DeleteBehavior.Restrict);
            entity.HasOne<Conversation>().WithMany().HasForeignKey(i => i.ConversationId).OnDelete(DeleteBehavior.Restrict);
            entity.HasIndex(i => new { i.OwnerId, i.CreatedAt });
        });
        builder.Entity<Message>().HasOne<NormalImage>().WithMany().HasForeignKey(m => m.NormalImageId).OnDelete(DeleteBehavior.Restrict);
        builder.Entity<Message>().HasIndex(m => m.NormalImageId).IsUnique();
        builder.Entity<Conversation>().HasOne<CommunityArticle>().WithMany().HasForeignKey(c => c.ArticleId).OnDelete(DeleteBehavior.Restrict);
        builder.Entity<Conversation>().HasIndex(c => new { c.ArticleId, c.InitiatorId }).IsUnique();
    }
}
