using Microsoft.AspNetCore.Identity.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore;
using FruitVision.Api.Ai;

namespace FruitVision.Api.Data;

public class AppDbContext(DbContextOptions<AppDbContext> options) : IdentityUserContext<AppUser, Guid>(options)
{
    public DbSet<AuthSession> AuthSessions => Set<AuthSession>();
    public DbSet<ConsumedRefresh> ConsumedRefreshes => Set<ConsumedRefresh>();
    public DbSet<LoginChallenge> LoginChallenges => Set<LoginChallenge>();
    public DbSet<AuditEntry> AuditEntries => Set<AuditEntry>();
    public DbSet<Product> Products => Set<Product>();
    public DbSet<Post> Posts => Set<Post>();
    public DbSet<Conversation> Conversations => Set<Conversation>();
    public DbSet<Participant> Participants => Set<Participant>();
    public DbSet<Message> Messages => Set<Message>();
    public DbSet<InteractionHistory> InteractionHistories => Set<InteractionHistory>();
    public DbSet<OutboxEvent> OutboxEvents => Set<OutboxEvent>();
    public DbSet<SeedRun> SeedRuns => Set<SeedRun>();
    public DbSet<AiJob> AiJobs => Set<AiJob>();

    protected override void OnModelCreating(ModelBuilder b)
    {
        base.OnModelCreating(b);
        AiJob.ConfigureModel(b);
        b.Entity<AppUser>(e => {
            e.Property(x => x.DisplayName).HasMaxLength(100);
            e.Property(x => x.Region).HasMaxLength(120);
            e.Property(x => x.ReviewReason).HasMaxLength(1000);
            e.Property(x => x.Role).HasConversion<string>().HasMaxLength(16);
            e.Property(x => x.ApprovalStatus).HasConversion<string>().HasMaxLength(24);
            e.HasIndex(x => x.NormalizedEmail).IsUnique();
            e.ToTable(t => {
                t.HasCheckConstraint("CK_User_Role", "\"Role\" IN ('Admin','Producer','Trader','Consumer')");
                t.HasCheckConstraint("CK_User_Approval", "\"ApprovalStatus\" IN ('Pending','NeedsInformation','Approved','Rejected')");
            });
        });
        b.Entity<AuthSession>(e => {
            e.HasIndex(x => x.AccessHash).IsUnique();
            e.HasIndex(x => x.RefreshHash).IsUnique();
            e.HasIndex(x => new { x.UserId, x.RevokedAt });
            e.Property(x => x.AccessHash).HasMaxLength(64);
            e.Property(x => x.RefreshHash).HasMaxLength(64);
            e.Property(x => x.SecurityStamp).HasMaxLength(128);
        });
        b.Entity<ConsumedRefresh>().HasKey(x => x.Hash);
        b.Entity<ConsumedRefresh>().Property(x => x.Hash).HasMaxLength(64);
        b.Entity<LoginChallenge>().HasKey(x => x.Hash);
        b.Entity<LoginChallenge>().Property(x => x.Hash).HasMaxLength(64);
        b.Entity<AuditEntry>(e => {
            e.HasIndex(x => new { x.SubjectId, x.CreatedAt });
            e.Property(x => x.Action).HasMaxLength(80);
            e.Property(x => x.Reason).HasMaxLength(1000);
        });
        b.Entity<Product>().HasKey(x => x.Code);
        b.Entity<Product>().Property(x => x.Code).HasMaxLength(40);
        b.Entity<Product>().Property(x => x.Name).HasMaxLength(120);
        b.Entity<Post>(e => {
            e.HasIndex(x => new { x.Status, x.CreatedAt, x.Id });
            e.HasIndex(x => new { x.AuthorId, x.CreatedAt });
            e.Property(x => x.Title).HasMaxLength(160);
            e.Property(x => x.Body).HasMaxLength(5000);
            e.Property(x => x.ProductCode).HasMaxLength(40);
            e.Property(x => x.EstimatedQuantityKg).HasPrecision(14,3);
            e.Property(x => x.Revision).HasDefaultValue(1);
            e.Property(x => x.ReviewReason).HasMaxLength(1000);
            e.Property(x => x.Region).HasMaxLength(120).HasDefaultValue("");
            e.Property(x => x.Purpose).HasMaxLength(16).HasDefaultValue("Supply");
            e.Property(x => x.PriceMinVndPerKg).HasPrecision(14,2);
            e.Property(x => x.PriceMaxVndPerKg).HasPrecision(14,2);
            e.HasOne<AppUser>().WithMany().HasForeignKey(x => x.ReviewedById).OnDelete(DeleteBehavior.Restrict);
            e.ToTable(t => {
                t.HasCheckConstraint("CK_Post_Status", "\"Status\" IN ('AwaitingReview','Published','Rejected','Paused','Draft','NeedsChanges','Closed')");
                t.HasCheckConstraint("CK_Post_Revision", "\"Revision\" >= 1");
                t.HasCheckConstraint("CK_Post_Purpose", "\"Purpose\" IN ('Supply','Demand')");
                t.HasCheckConstraint("CK_Post_Prices", "(\"PriceMinVndPerKg\" IS NULL AND \"PriceMaxVndPerKg\" IS NULL) OR (\"PriceMinVndPerKg\" IS NOT NULL AND \"PriceMaxVndPerKg\" IS NOT NULL AND \"PriceMinVndPerKg\" > 0 AND \"PriceMaxVndPerKg\" >= \"PriceMinVndPerKg\")");
            });
            e.HasOne<Product>().WithMany().HasForeignKey(x => x.ProductCode);
        });
        b.Entity<Conversation>(e => {
            e.Property(x => x.Kind).HasMaxLength(16).HasDefaultValue("Direct");
            e.Property(x => x.Region).HasMaxLength(120);
            e.Property(x => x.ProductCode).HasMaxLength(40);

            e.Property(x => x.IsOpen).HasDefaultValue(true);
            e.HasIndex(x => new { x.PostId, x.InitiatorId }).IsUnique();
            e.HasIndex(x => new { x.Kind, x.IsOpen, x.CreatedAt, x.Id });
            e.HasIndex(x => new { x.Region, x.ProductCode });
            e.HasOne<AppUser>().WithMany().HasForeignKey(x => x.OwnerId).OnDelete(DeleteBehavior.Restrict);
            e.HasOne<AppUser>().WithMany().HasForeignKey(x => x.InitiatorId).OnDelete(DeleteBehavior.Restrict);
            e.HasOne<Product>().WithMany().HasForeignKey(x => x.ProductCode).OnDelete(DeleteBehavior.Restrict);
            e.ToTable(t => t.HasCheckConstraint("CK_Conversation_Kind", "\"Kind\" IN ('Direct','Group')"));
        });
        b.Entity<Participant>(e => {
            e.HasKey(x => new { x.ConversationId, x.UserId });
            e.HasIndex(x => x.UserId);
            e.HasOne<Conversation>().WithMany().HasForeignKey(x => x.ConversationId);
            e.HasOne<AppUser>().WithMany().HasForeignKey(x => x.UserId);
        });
        b.Entity<Message>(e => {
            e.HasIndex(x => new { x.ConversationId, x.CreatedAt, x.Id });
            e.HasIndex(x => new { x.ConversationId, x.SenderId, x.ClientMessageId }).IsUnique();
            e.Property(x => x.ClientMessageId).HasMaxLength(64);
            e.Property(x => x.Text).HasMaxLength(2000);
            e.HasOne<Conversation>().WithMany().HasForeignKey(x => x.ConversationId);
            e.HasOne<AppUser>().WithMany().HasForeignKey(x => x.SenderId);
        });
        b.Entity<InteractionHistory>().HasIndex(x => new { x.UserId, x.CreatedAt, x.Id });
        b.Entity<OutboxEvent>().HasIndex(x => new { x.SentAt, x.CreatedAt });
        b.Entity<SeedRun>().HasKey(x => x.Id);
    }
}

