using Microsoft.EntityFrameworkCore;

namespace FruitVision.Api.Data;

public sealed class ArticleLike
{
    public Guid ArticleId { get; set; }
    public Guid UserId { get; set; }
    public DateTimeOffset CreatedAt { get; set; } = DateTimeOffset.UtcNow;
}

public sealed class ArticleComment
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public Guid ArticleId { get; set; }
    public Guid UserId { get; set; }
    public Guid ClientCommentId { get; set; }
    public string Body { get; set; } = "";
    public DateTimeOffset CreatedAt { get; set; } = DateTimeOffset.UtcNow;
}

public static class ArticleEngagementModels
{
    public static void ConfigureModel(ModelBuilder builder)
    {
        builder.Entity<ArticleLike>(entity =>
        {
            entity.ToTable("ArticleLikes");
            entity.HasKey(like => new { like.ArticleId, like.UserId });
            entity.HasOne<CommunityArticle>().WithMany().HasForeignKey(like => like.ArticleId).OnDelete(DeleteBehavior.Cascade);
            entity.HasOne<AppUser>().WithMany().HasForeignKey(like => like.UserId).OnDelete(DeleteBehavior.Restrict);
        });
        builder.Entity<ArticleComment>(entity =>
        {
            entity.ToTable("ArticleComments");
            entity.Property(comment => comment.Body).HasMaxLength(1000);
            entity.HasIndex(comment => new { comment.ArticleId, comment.UserId, comment.ClientCommentId }).IsUnique();
            entity.HasIndex(comment => new { comment.ArticleId, comment.CreatedAt, comment.Id });
            entity.HasOne<CommunityArticle>().WithMany().HasForeignKey(comment => comment.ArticleId).OnDelete(DeleteBehavior.Cascade);
            entity.HasOne<AppUser>().WithMany().HasForeignKey(comment => comment.UserId).OnDelete(DeleteBehavior.Restrict);
        });
    }
}
