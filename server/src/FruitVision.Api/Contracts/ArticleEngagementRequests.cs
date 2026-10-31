using System.ComponentModel.DataAnnotations;
using System.Text.Json.Serialization;

namespace FruitVision.Api.Contracts;

public sealed record SetArticleLikeRequest([property: JsonRequired] bool Liked);
public sealed record CreateArticleCommentRequest(
    [property: Required, StringLength(1000, MinimumLength = 2)] string Body,
    [property: JsonRequired] Guid ClientCommentId);
public sealed record ArticleEngagementView(Guid ArticleId, int LikeCount, int CommentCount, bool Liked);
public sealed record ArticleCommentAuthorView(Guid Id, string DisplayName, string Role);
public sealed record ArticleCommentView(Guid Id, Guid ArticleId, Guid ClientCommentId, string Body,
    DateTimeOffset CreatedAt, ArticleCommentAuthorView Author, bool CanDelete);
