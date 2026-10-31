using System.ComponentModel.DataAnnotations;

namespace FruitVision.Api.Contracts;

public sealed record UpdateProfileRequest(
    [property: Required, StringLength(100, MinimumLength = 2)] string DisplayName,
    [property: StringLength(500)] string? Bio,
    [property: StringLength(30)] string? Phone,
    [property: Required, RegularExpression("^(Unknown|Female|Male|Other)$")] string Gender,
    bool ShowGender = false, bool ShowPhone = false, bool ShowRegion = false);
