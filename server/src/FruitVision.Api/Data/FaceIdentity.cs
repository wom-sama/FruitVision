using Microsoft.EntityFrameworkCore;

namespace FruitVision.Api.Data;

public sealed class FaceIdentity
{
    public Guid UserId { get; set; }
    public string ProtectedEmbedding { get; set; } = "";
    public string ModelSha256 { get; set; } = "";
    public DateTimeOffset EnrolledAt { get; set; } = DateTimeOffset.UtcNow;
    public DateTimeOffset UpdatedAt { get; set; } = DateTimeOffset.UtcNow;

    public static void ConfigureModel(ModelBuilder builder)
    {
        builder.Entity<FaceIdentity>(entity =>
        {
            entity.HasKey(face => face.UserId);
            entity.Property(face => face.ProtectedEmbedding).HasMaxLength(8192);
            entity.Property(face => face.ModelSha256).HasMaxLength(64);
            entity.HasOne<AppUser>().WithMany().HasForeignKey(face => face.UserId).OnDelete(DeleteBehavior.Cascade);
        });
    }
}
