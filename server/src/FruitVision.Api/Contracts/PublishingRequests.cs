using System.ComponentModel.DataAnnotations;
using System.Text.Json.Serialization;

namespace FruitVision.Api.Contracts;

public sealed record CreateArticleRequest(
    [property: Required, StringLength(160, MinimumLength = 5)] string Title,
    [property: Required, StringLength(5000, MinimumLength = 10)] string Body,
    Guid? ImageId = null, Guid? BranchId = null);
public sealed record UpdateArticleRequest(
    [property: Required, StringLength(160, MinimumLength = 5)] string Title,
    [property: Required, StringLength(5000, MinimumLength = 10)] string Body,
    [property: JsonRequired, Range(1, int.MaxValue)] int ExpectedRevision,
    Guid? ImageId = null, Guid? BranchId = null);
public sealed record PublishingRevisionRequest([property: JsonRequired, Range(1, int.MaxValue)] int ExpectedRevision);
public sealed record PublishingReviewRequest(
    [property: Required, StringLength(24)] string Status,
    [property: Required, StringLength(1000, MinimumLength = 3)] string Reason,
    [property: JsonRequired, Range(1, int.MaxValue)] int ExpectedRevision);
public sealed record CreateBranchRequest(
    [property: Required, StringLength(160, MinimumLength = 2)] string Name,
    [property: Required, StringLength(2, MinimumLength = 2)] string CountryCode,
    [property: Required, StringLength(128)] string ProvinceCode,
    [property: Required, StringLength(240, MinimumLength = 5)] string Street,
    [property: Required, StringLength(30, MinimumLength = 7)] string Phone);
public sealed record UpdateBranchRequest(
    [property: Required, StringLength(160, MinimumLength = 2)] string Name,
    [property: Required, StringLength(2, MinimumLength = 2)] string CountryCode,
    [property: Required, StringLength(128)] string ProvinceCode,
    [property: Required, StringLength(240, MinimumLength = 5)] string Street,
    [property: Required, StringLength(30, MinimumLength = 7)] string Phone,
    [property: JsonRequired, Range(1, int.MaxValue)] int ExpectedRevision);
