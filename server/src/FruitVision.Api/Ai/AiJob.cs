using System.Text.Json;
using FruitVision.Api.Data;
using Microsoft.EntityFrameworkCore;

namespace FruitVision.Api.Ai;

public enum AiJobStatus { Queued, Running, Succeeded, Failed, Cancelled }

public sealed class AiJob
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public Guid UserId { get; set; }
    public string ClientRequestId { get; set; } = "";
    public string MediaType { get; set; } = "";
    public string ContentType { get; set; } = "";
    public string InputExtension { get; set; } = "";
    public long InputBytes { get; set; }
    public string InputSha256 { get; set; } = "";
    public AiJobStatus Status { get; set; } = AiJobStatus.Queued;
    public int Progress { get; set; }
    public int FramesProcessed { get; set; }
    public long Revision { get; set; } = 1;
    public DateTimeOffset CreatedAt { get; set; } = DateTimeOffset.UtcNow;
    public DateTimeOffset? CompletedAt { get; set; }
    public string? Error { get; set; }
    public string? ResultJson { get; set; }
    public bool PreviewAvailable { get; set; }

    public static void ConfigureModel(ModelBuilder builder)
    {
        builder.Entity<AiJob>(entity =>
        {
            entity.ToTable("AiJobs", table =>
            {
                table.HasCheckConstraint("CK_AiJob_Status", "\"Status\" IN ('Queued','Running','Succeeded','Failed','Cancelled')");
                table.HasCheckConstraint("CK_AiJob_MediaType", "\"MediaType\" IN ('image','video')");
                table.HasCheckConstraint("CK_AiJob_Progress", "\"Progress\" BETWEEN 0 AND 100 AND \"FramesProcessed\" >= 0");
            });
            entity.HasKey(job => job.Id);
            entity.Property(job => job.Status).HasConversion<string>().HasMaxLength(16);
            entity.Property(job => job.ClientRequestId).HasMaxLength(64);
            entity.Property(job => job.MediaType).HasMaxLength(8);
            entity.Property(job => job.ContentType).HasMaxLength(32);
            entity.Property(job => job.InputExtension).HasMaxLength(8);
            entity.Property(job => job.InputSha256).HasMaxLength(64);
            entity.Property(job => job.Error).HasMaxLength(300);
            entity.Property(job => job.ResultJson).HasColumnType("jsonb");
            entity.HasIndex(job => new { job.UserId, job.ClientRequestId }).IsUnique();
            entity.HasIndex(job => new { job.UserId, job.CreatedAt });
            entity.HasIndex(job => new { job.Status, job.CreatedAt });
            entity.HasIndex(job => job.UserId).IsUnique().HasFilter("\"Status\" IN ('Queued','Running')");
            entity.HasOne<AppUser>().WithMany().HasForeignKey(job => job.UserId).OnDelete(DeleteBehavior.Restrict);
        });
    }
}

public sealed record AiJobView(Guid Id, string MediaType, string Status, int Progress,
    int FramesProcessed, long Revision, DateTimeOffset CreatedAt, DateTimeOffset? CompletedAt,
    string? Error, JsonElement? Result, bool PreviewAvailable)
{
    public static AiJobView From(AiJob job) => new(job.Id, job.MediaType, job.Status.ToString(),
        job.Progress, job.FramesProcessed, job.Revision, job.CreatedAt, job.CompletedAt, job.Error,
        job.ResultJson is null ? null : JsonSerializer.Deserialize<JsonElement>(job.ResultJson),
        job.PreviewAvailable);
}
