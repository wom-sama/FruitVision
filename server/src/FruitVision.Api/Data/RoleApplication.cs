using Microsoft.EntityFrameworkCore;

namespace FruitVision.Api.Data;

public sealed class RoleApplication
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public Guid UserId { get; set; }
    public AccountRole RequestedRole { get; set; }
    public string Status { get; set; } = "Draft";
    public int Revision { get; set; } = 1;
    public string OrganisationName { get; set; } = "";
    public string Address { get; set; } = "";
    public string Region { get; set; } = "";
    public string CountryCode { get; set; } = "";
    public string ProvinceCode { get; set; } = "";
    public string Phone { get; set; } = "";
    public string[] Products { get; set; } = [];
    public decimal? CultivatedAreaHa { get; set; }
    public string? TaxCode { get; set; }
    public string? BusinessRegistrationNumber { get; set; }
    public DateTimeOffset CreatedAt { get; set; } = DateTimeOffset.UtcNow;
    public DateTimeOffset UpdatedAt { get; set; } = DateTimeOffset.UtcNow;
    public DateTimeOffset? SubmittedAt { get; set; }
    public DateTimeOffset? ReviewedAt { get; set; }
    public Guid? ReviewedById { get; set; }
    public string? ReviewReason { get; set; }

    public static void ConfigureModel(ModelBuilder model)
    {
        model.Entity<RoleApplication>(e =>
        {
            e.ToTable("RoleApplications", t =>
            {
                t.HasCheckConstraint("CK_RoleApplication_Role", "\"RequestedRole\" IN ('Producer','Trader')");
                t.HasCheckConstraint("CK_RoleApplication_Status", "\"Status\" IN ('Draft','Submitted','NeedsInformation','Approved','Rejected')");
                t.HasCheckConstraint("CK_RoleApplication_Revision", "\"Revision\" >= 1");
            });
            e.HasKey(x => x.Id);
            e.Property(x => x.RequestedRole).HasConversion<string>().HasMaxLength(16);
            e.Property(x => x.Status).HasMaxLength(24);
            e.Property(x => x.OrganisationName).HasMaxLength(160);
            e.Property(x => x.Address).HasMaxLength(300);
            e.Property(x => x.Region).HasMaxLength(120);
            e.Property(x => x.CountryCode).HasMaxLength(2);
            e.Property(x => x.ProvinceCode).HasMaxLength(128);
            e.Property(x => x.Phone).HasMaxLength(24);
            e.Property(x => x.CultivatedAreaHa).HasPrecision(12, 3);
            e.Property(x => x.TaxCode).HasMaxLength(40);
            e.Property(x => x.BusinessRegistrationNumber).HasMaxLength(80);
            e.Property(x => x.ReviewReason).HasMaxLength(1000);
            e.HasIndex(x => x.UserId).IsUnique().HasFilter("\"Status\" IN ('Draft','Submitted','NeedsInformation')");
            e.HasIndex(x => new { x.Status, x.CreatedAt, x.Id });
            e.HasOne<AppUser>().WithMany().HasForeignKey(x => x.UserId).OnDelete(DeleteBehavior.Restrict);
            e.HasOne<AppUser>().WithMany().HasForeignKey(x => x.ReviewedById).OnDelete(DeleteBehavior.Restrict);
        });
        model.Entity<RoleApplicationEvidence>(e =>
        {
            e.ToTable("RoleApplicationEvidence", t =>
            {
                t.HasCheckConstraint("CK_RoleEvidence_Category", "\"Category\" IN ('ProductionEvidence','BusinessEvidence')");
                t.HasCheckConstraint("CK_RoleEvidence_Size", "\"SizeBytes\" > 0 AND \"SizeBytes\" <= 5242880");
            });
            e.HasKey(x => x.Id);
            e.Property(x => x.Category).HasMaxLength(24);
            e.Property(x => x.ContentType).HasMaxLength(40);
            e.Property(x => x.Sha256).HasMaxLength(64);
            e.HasIndex(x => new { x.ApplicationId, x.CreatedAt, x.Id });
            e.HasOne<RoleApplication>().WithMany().HasForeignKey(x => x.ApplicationId).OnDelete(DeleteBehavior.Cascade);
        });
    }
}

public sealed class RoleApplicationEvidence
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public Guid ApplicationId { get; set; }
    public string Category { get; set; } = "";
    public string ContentType { get; set; } = "";
    public long SizeBytes { get; set; }
    public string Sha256 { get; set; } = "";
    public DateTimeOffset CreatedAt { get; set; } = DateTimeOffset.UtcNow;
}
