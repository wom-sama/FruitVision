using System.ComponentModel.DataAnnotations;
using System.Text.Json.Serialization;
using FruitVision.Api.Data;

namespace FruitVision.Api.Contracts;

public record RegisterRequest(
    [property:Required,StringLength(100,MinimumLength=2)] string DisplayName,
    [property:Required,EmailAddress,StringLength(254)] string Email,
    [property:Required,StringLength(128,MinimumLength=12)] string Password,
    [property:JsonRequired] BusinessRole Role,
    [property:Required,StringLength(120,MinimumLength=2)] string Region);
public record LoginRequest(
    [property:Required,EmailAddress,StringLength(254)] string Email,
    [property:Required,StringLength(128)] string Password);
public record RefreshRequest([property:Required,StringLength(100,MinimumLength=43)] string RefreshToken);
public record MfaLoginRequest(
    [property:Required,StringLength(100,MinimumLength=43)] string ChallengeToken,
    [property:Required,RegularExpression("^[0-9]{6}$")] string Code);
public record PasswordRequest([property:Required,StringLength(128)] string Password);
public record MfaCodeRequest([property:Required,RegularExpression("^[0-9]{6}$")] string Code);
public record ReviewRequest(ApprovalState Status, [property:Required,StringLength(1000,MinimumLength=3)] string Reason);
public record AccountStatusRequest(bool IsActive,[property:Required,StringLength(1000,MinimumLength=3)] string Reason);
public record ProfileRequest(
    [property:Required,StringLength(100,MinimumLength=2)] string DisplayName,
    [property:Required,StringLength(120,MinimumLength=2)] string Region);
public record CreatePostRequest(
    [property:Required,StringLength(160,MinimumLength=5)] string Title,
    [property:Required,StringLength(5000,MinimumLength=10)] string Body,
    [property:Required,StringLength(40)] string ProductCode,
    [property:Range(typeof(decimal),"0.001","1000000",ParseLimitsInInvariantCulture=true,ConvertValueInInvariantCulture=true)] decimal EstimatedQuantityKg,
    [property:StringLength(120,MinimumLength=2)] string? Region = null,
    string? Purpose = null, DateOnly? AvailableOn = null,
    decimal? PriceMinVndPerKg = null, decimal? PriceMaxVndPerKg = null);
public record PostReviewRequest(
    [property:Required] string Status,
    [property:Required,StringLength(1000,MinimumLength=3)] string Reason,
    [property:JsonRequired,Range(1,int.MaxValue)] int ExpectedRevision);
public record ContactPostRequest;
public record SendMessageRequest(
    [property:Required,RegularExpression("^[A-Za-z0-9_-]{8,64}$")] string ClientMessageId,
    [property:Required,StringLength(2000)] string Text);
