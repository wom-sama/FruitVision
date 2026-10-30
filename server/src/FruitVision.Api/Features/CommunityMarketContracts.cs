using System.ComponentModel.DataAnnotations;

namespace FruitVision.Api.Contracts;

public sealed record CreateCommunityGroupRequest(
    [property: Required, StringLength(160, MinimumLength = 5)] string Title,
    [property: Required, StringLength(120, MinimumLength = 2)] string Region,
    [property: StringLength(40)] string? ProductCode = null);

// Binding an empty object preserves the API's strict rejection of arbitrary participant IDs.
public sealed record CommunityActionRequest;

public sealed record CommunityGroupView(Guid Id, string Title, string Kind, Guid? OwnerId,
    string? Region, string? ProductCode, bool IsOpen, DateTimeOffset CreatedAt,
    int MemberCount, bool IsMember, string CurrentRole);
