using System.ComponentModel.DataAnnotations;
using System.Text.Json.Serialization;

namespace FruitVision.Api.Contracts;

public sealed record CreateRoleApplicationRequest([property: Required] string RequestedRole);
public sealed record RoleApplicationProfileRequest(
    [property: Required, StringLength(160, MinimumLength = 2)] string OrganisationName,
    [property: Required, StringLength(300, MinimumLength = 5)] string Address,
    [property: Required, RegularExpression("^[A-Z]{2}$")] string CountryCode,
    [property: Required, StringLength(128, MinimumLength = 1)] string ProvinceCode,
    [property: Required, StringLength(24, MinimumLength = 8)] string Phone,
    [property: Required, MinLength(1), MaxLength(8)] string[] Products,
    [property: JsonRequired, Range(1, int.MaxValue)] int ExpectedRevision,
    decimal? CultivatedAreaHa = null,
    [property: StringLength(40)] string? TaxCode = null,
    [property: StringLength(80)] string? BusinessRegistrationNumber = null);
public sealed record RoleApplicationSubmitRequest([property: JsonRequired, Range(1, int.MaxValue)] int ExpectedRevision);
public sealed record RoleApplicationReviewRequest(
    [property: Required] string Status,
    [property: Required, StringLength(1000, MinimumLength = 3)] string Reason,
    [property: JsonRequired, Range(1, int.MaxValue)] int ExpectedRevision);

public sealed record RoleApplicationEvidenceView(Guid Id, string Category, string ContentType, long SizeBytes,
    DateTimeOffset CreatedAt, string DownloadPath);
public sealed record RoleApplicationApplicantView(Guid Id, string DisplayName, string Role);
public sealed record RoleApplicationView(Guid Id, Guid UserId, string RequestedRole, string Status, int Revision,
    string OrganisationName, string Address, string CountryCode, string ProvinceCode, string Region, string Phone, string[] Products,
    decimal? CultivatedAreaHa, string? TaxCode, string? BusinessRegistrationNumber,
    DateTimeOffset CreatedAt, DateTimeOffset UpdatedAt, DateTimeOffset? SubmittedAt,
    DateTimeOffset? ReviewedAt, string? ReviewReason, IReadOnlyList<RoleApplicationEvidenceView> Evidence,
    RoleApplicationApplicantView Applicant);
