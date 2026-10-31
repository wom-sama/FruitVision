using Microsoft.EntityFrameworkCore;

namespace FruitVision.Api.Data;

public sealed class CommunityArticle
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public Guid AuthorId { get; set; }
    public AppUser Author { get; set; } = null!;
    public string Title { get; set; } = "";
    public string Body { get; set; } = "";
    public string AudienceLane { get; set; } = "Community";
    public Guid? BranchId { get; set; }
    public SellerBranch? Branch { get; set; }
    public Guid? ImageId { get; set; }
    public NormalImage? Image { get; set; }
    public string Status { get; set; } = "AwaitingReview";
    public int Revision { get; set; } = 1;
    public string? ReviewReason { get; set; }
    public DateTimeOffset? ReviewedAt { get; set; }
    public Guid? ReviewedById { get; set; }
    public DateTimeOffset CreatedAt { get; set; } = DateTimeOffset.UtcNow;
    public DateTimeOffset UpdatedAt { get; set; } = DateTimeOffset.UtcNow;
}

public sealed class SellerBranch
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public Guid OwnerId { get; set; }
    public AppUser Owner { get; set; } = null!;
    public string Name { get; set; } = "";
    public string CountryCode { get; set; } = "";
    public string ProvinceCode { get; set; } = "";
    public string CountryName { get; set; } = "";
    public string ProvinceName { get; set; } = "";
    public string Region { get; set; } = "";
    public string Street { get; set; } = "";
    public string Phone { get; set; } = "";
    public string Status { get; set; } = "Pending";
    public int Revision { get; set; } = 1;
    public string? ReviewReason { get; set; }
    public DateTimeOffset? ReviewedAt { get; set; }
    public Guid? ReviewedById { get; set; }
    public DateTimeOffset CreatedAt { get; set; } = DateTimeOffset.UtcNow;
    public DateTimeOffset UpdatedAt { get; set; } = DateTimeOffset.UtcNow;
}

public static class PublishingModels
{
    public static void ConfigureModel(ModelBuilder builder)
    {
        builder.Entity<CommunityArticle>(entity =>
        {
            entity.ToTable("CommunityArticles", table =>
            {
                table.HasCheckConstraint("CK_Article_Status", "\"Status\" IN ('AwaitingReview','Published','Rejected','Paused','Deleted')");
                table.HasCheckConstraint("CK_Article_Revision", "\"Revision\" >= 1");
                table.HasCheckConstraint("CK_Article_Lane", "(\"AudienceLane\"='Community' AND \"BranchId\" IS NULL) OR (\"AudienceLane\"='Professional' AND \"BranchId\" IS NOT NULL)");
            });
            entity.Property(article => article.Title).HasMaxLength(160);
            entity.Property(article => article.Body).HasMaxLength(5000);
            entity.Property(article => article.AudienceLane).HasMaxLength(20).HasDefaultValue("Community");
            entity.Property(article => article.Status).HasMaxLength(24);
            entity.Property(article => article.ReviewReason).HasMaxLength(1000);
            entity.HasIndex(article => new { article.Status, article.CreatedAt, article.Id });
            entity.HasIndex(article => new { article.AuthorId, article.CreatedAt, article.Id });
            entity.HasOne(article => article.Author).WithMany().HasForeignKey(article => article.AuthorId).OnDelete(DeleteBehavior.Restrict);
            entity.HasOne<AppUser>().WithMany().HasForeignKey(article => article.ReviewedById).OnDelete(DeleteBehavior.Restrict);
            entity.HasOne(article => article.Branch).WithMany().HasForeignKey(article => article.BranchId).OnDelete(DeleteBehavior.Restrict);
            entity.HasOne(article => article.Image).WithMany().HasForeignKey(article => article.ImageId).OnDelete(DeleteBehavior.Restrict);
            entity.HasIndex(article => article.ImageId).IsUnique();
            entity.HasIndex(article => new { article.AudienceLane, article.Status, article.CreatedAt, article.Id });
        });
        builder.Entity<SellerBranch>(entity =>
        {
            entity.ToTable("SellerBranches", table =>
            {
                table.HasCheckConstraint("CK_Branch_Status", "\"Status\" IN ('Pending','Approved','Rejected','NeedsInformation','Deleted')");
                table.HasCheckConstraint("CK_Branch_Revision", "\"Revision\" >= 1");
            });
            entity.Property(branch => branch.Name).HasMaxLength(160);
            entity.Property(branch => branch.CountryCode).HasMaxLength(2);
            entity.Property(branch => branch.ProvinceCode).HasMaxLength(128);
            entity.Property(branch => branch.CountryName).HasMaxLength(120);
            entity.Property(branch => branch.ProvinceName).HasMaxLength(120);
            entity.Property(branch => branch.Region).HasMaxLength(120);
            entity.Property(branch => branch.Street).HasMaxLength(240);
            entity.Property(branch => branch.Phone).HasMaxLength(30);
            entity.Property(branch => branch.Status).HasMaxLength(24);
            entity.Property(branch => branch.ReviewReason).HasMaxLength(1000);
            entity.HasIndex(branch => new { branch.Status, branch.CreatedAt, branch.Id });
            entity.HasIndex(branch => new { branch.OwnerId, branch.Status, branch.CreatedAt });
            entity.HasOne(branch => branch.Owner).WithMany().HasForeignKey(branch => branch.OwnerId).OnDelete(DeleteBehavior.Restrict);
            entity.HasOne<AppUser>().WithMany().HasForeignKey(branch => branch.ReviewedById).OnDelete(DeleteBehavior.Restrict);
        });
    }
}
