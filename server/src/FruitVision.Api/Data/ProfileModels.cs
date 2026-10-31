using Microsoft.EntityFrameworkCore;

namespace FruitVision.Api.Data;

public sealed class UserProfile
{
    public Guid UserId { get; set; }
    public string Bio { get; set; } = "";
    public string Gender { get; set; } = "Unknown";
    public string? Phone { get; set; }
    public bool ShowGender { get; set; }
    public bool ShowPhone { get; set; }
    public bool ShowRegion { get; set; }
    public DateTimeOffset UpdatedAt { get; set; } = DateTimeOffset.UtcNow;
}

public sealed class UserBlock
{
    public Guid OwnerUserId { get; set; }
    public Guid BlockedUserId { get; set; }
    public DateTimeOffset CreatedAt { get; set; } = DateTimeOffset.UtcNow;
}

public static class ProfileModels
{
    public static void ConfigureModel(ModelBuilder model)
    {
        model.Entity<UserProfile>(e =>
        {
            e.ToTable("UserProfiles", t => t.HasCheckConstraint("CK_UserProfile_Gender", "\"Gender\" IN ('Unknown','Female','Male','Other')"));
            e.HasKey(x => x.UserId);
            e.Property(x => x.Bio).HasMaxLength(500);
            e.Property(x => x.Gender).HasMaxLength(16);
            e.Property(x => x.Phone).HasMaxLength(30);
            e.HasOne<AppUser>().WithOne().HasForeignKey<UserProfile>(x => x.UserId).OnDelete(DeleteBehavior.Cascade);
        });
        model.Entity<UserBlock>(e =>
        {
            e.ToTable("UserBlocks", t => t.HasCheckConstraint("CK_UserBlock_NotSelf", "\"OwnerUserId\" <> \"BlockedUserId\""));
            e.HasKey(x => new { x.OwnerUserId, x.BlockedUserId });
            e.HasIndex(x => new { x.BlockedUserId, x.OwnerUserId });
            e.HasOne<AppUser>().WithMany().HasForeignKey(x => x.OwnerUserId).OnDelete(DeleteBehavior.Restrict);
            e.HasOne<AppUser>().WithMany().HasForeignKey(x => x.BlockedUserId).OnDelete(DeleteBehavior.Restrict);
        });
    }
}

public static class ProfileBlocks
{
    // Callers serializing a write acquire both user rows in UUID order before this check.
    public static Task<bool> IsEitherBlockedAsync(AppDbContext db, Guid first, Guid second, CancellationToken ct = default) =>
        db.Set<UserBlock>().AnyAsync(b => (b.OwnerUserId == first && b.BlockedUserId == second) ||
            (b.OwnerUserId == second && b.BlockedUserId == first), ct);

    public sealed record SendAccess(Conversation? Conversation, AppUser? Sender, bool Blocked = false);

    public static async Task<SendAccess> LockNormalSendAsync(AppDbContext db, Guid id, Guid senderId, CancellationToken ct = default)
    {
        var kind = await db.Conversations.AsNoTracking().Where(c => c.Id == id).Select(c => c.Kind).SingleOrDefaultAsync(ct);
        if (kind is not ("Direct" or "Group")) return new(null, null);
        Guid[] pair = []; List<AppUser> users = [];
        if (kind == "Direct")
        {
            pair = await db.Participants.AsNoTracking().Where(p => p.ConversationId == id).OrderBy(p => p.UserId).Select(p => p.UserId).ToArrayAsync(ct);
            if (pair.Length != 2 || !pair.Contains(senderId)) return new(null, null);
            var first = pair[0]; var second = pair[1];
            users = await db.Users.FromSqlInterpolated($"SELECT * FROM \"AspNetUsers\" WHERE \"Id\"={first} OR \"Id\"={second} ORDER BY \"Id\" FOR SHARE").ToListAsync(ct);
        }
        var conversation = await db.Conversations.FromSqlInterpolated($"SELECT * FROM \"Conversations\" WHERE \"Id\"={id} FOR UPDATE").SingleOrDefaultAsync(ct);
        if (conversation is null || conversation.Kind != kind) return new(null, null);
        var members = await db.Participants.AsNoTracking().Where(p => p.ConversationId == id).OrderBy(p => p.UserId).Select(p => p.UserId).ToArrayAsync(ct);
        if (!members.Contains(senderId) || (kind == "Direct" && !members.SequenceEqual(pair))) return new(null, null);
        if (kind == "Group") users = await db.Users.FromSqlInterpolated($"SELECT * FROM \"AspNetUsers\" WHERE \"Id\"={senderId} FOR SHARE").ToListAsync(ct);
        var sender = users.SingleOrDefault(u => u.Id == senderId && u.IsActive && u.ApprovalStatus == ApprovalState.Approved);
        if (kind == "Direct" && users.Any(u => !u.IsActive || u.ApprovalStatus != ApprovalState.Approved)) return new(conversation, null);
        return new(conversation, sender, kind == "Direct" && await IsEitherBlockedAsync(db, pair[0], pair[1], ct));
    }
}
