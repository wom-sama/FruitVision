using Microsoft.AspNetCore.Identity;

namespace FruitVision.Api.Data;

public enum AccountRole { Admin, Producer, Trader, Consumer }
public enum BusinessRole { Producer, Trader, Consumer }
public enum ApprovalState { Pending, NeedsInformation, Approved, Rejected }

public class AppUser : IdentityUser<Guid>
{
    public string DisplayName { get; set; } = "";
    public string Region { get; set; } = "";
    public AccountRole Role { get; set; }
    public ApprovalState ApprovalStatus { get; set; } = ApprovalState.Pending;
    public string? ReviewReason { get; set; }
    public bool IsActive { get; set; } = true;
    public DateTimeOffset CreatedAt { get; set; } = DateTimeOffset.UtcNow;
}

public class AuthSession
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public Guid UserId { get; set; }
    public AppUser User { get; set; } = null!;
    public string AccessHash { get; set; } = "";
    public string RefreshHash { get; set; } = "";
    public string SecurityStamp { get; set; } = "";
    public DateTimeOffset CreatedAt { get; set; } = DateTimeOffset.UtcNow;
    public DateTimeOffset AccessExpiresAt { get; set; }
    public DateTimeOffset RefreshExpiresAt { get; set; }
    public DateTimeOffset? RevokedAt { get; set; }
}

public class ConsumedRefresh
{
    public string Hash { get; set; } = "";
    public Guid SessionId { get; set; }
    public DateTimeOffset ExpiresAt { get; set; }
}

public class LoginChallenge
{
    public string Hash { get; set; } = "";
    public Guid UserId { get; set; }
    public string SecurityStamp { get; set; } = "";
    public int Attempts { get; set; }
    public DateTimeOffset ExpiresAt { get; set; }
    public bool Consumed { get; set; }
}

public class AuditEntry
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public Guid? ActorId { get; set; }
    public Guid? SubjectId { get; set; }
    public string Action { get; set; } = "";
    public string Reason { get; set; } = "";
    public DateTimeOffset CreatedAt { get; set; } = DateTimeOffset.UtcNow;
}

public class Product
{
    public string Code { get; set; } = "";
    public string Name { get; set; } = "";
    public string Unit { get; set; } = "kg";
}

public class Post
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public Guid AuthorId { get; set; }
    public AppUser Author { get; set; } = null!;
    public string Title { get; set; } = "";
    public string Body { get; set; } = "";
    public string ProductCode { get; set; } = "";
    public string Status { get; set; } = "AwaitingReview";
    public string SourceType { get; set; } = "Forecast";
    public decimal EstimatedQuantityKg { get; set; }
    public int Revision { get; set; } = 1;
    public string? ReviewReason { get; set; }
    public DateTimeOffset? ReviewedAt { get; set; }
    public Guid? ReviewedById { get; set; }
    public string Region { get; set; } = "";
    public string Purpose { get; set; } = "Supply";
    public DateOnly? AvailableOn { get; set; }
    public decimal? PriceMinVndPerKg { get; set; }
    public decimal? PriceMaxVndPerKg { get; set; }
    public DateTimeOffset CreatedAt { get; set; } = DateTimeOffset.UtcNow;
}

public class Conversation
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public string Title { get; set; } = "";
    public Guid? PostId { get; set; }
    public Guid? InitiatorId { get; set; }
    public string Kind { get; set; } = "Direct";
    public Guid? OwnerId { get; set; }
    public string? Region { get; set; }
    public string? ProductCode { get; set; }
    public bool IsOpen { get; set; } = true;
    public DateTimeOffset CreatedAt { get; set; } = DateTimeOffset.UtcNow;
}

public class Participant
{
    public Guid ConversationId { get; set; }
    public Guid UserId { get; set; }
}

public class Message
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public Guid ConversationId { get; set; }
    public Guid SenderId { get; set; }
    public string ClientMessageId { get; set; } = "";
    public string Text { get; set; } = "";
    public DateTimeOffset CreatedAt { get; set; } = DateTimeOffset.UtcNow;
}

public class InteractionHistory
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public Guid UserId { get; set; }
    public string Kind { get; set; } = "";
    public string Title { get; set; } = "";
    public string Body { get; set; } = "";
    public bool IsDemo { get; set; }
    public DateTimeOffset CreatedAt { get; set; } = DateTimeOffset.UtcNow;
}

public class OutboxEvent
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public Guid ConversationId { get; set; }
    public Guid MessageId { get; set; }
    public DateTimeOffset CreatedAt { get; set; } = DateTimeOffset.UtcNow;
    public DateTimeOffset? SentAt { get; set; }
}

public class SeedRun
{
    public string Id { get; set; } = "";
    public DateTimeOffset CreatedAt { get; set; } = DateTimeOffset.UtcNow;
}
