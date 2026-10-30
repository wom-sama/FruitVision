using System.ComponentModel.DataAnnotations;
using System.Text.Json.Serialization;

namespace FruitVision.Api.Contracts;

public sealed record RegisterSecretDeviceRequest(Guid DeviceId,
    [property: Required, StringLength(100, MinimumLength = 2)] string Label,
    [property: Required, StringLength(44, MinimumLength = 44)] string EncryptionPublicKey,
    [property: Required, StringLength(44, MinimumLength = 44)] string SigningPublicKey);
public sealed record CreateSecretConversationRequest(Guid DirectConversationId);
public sealed record SecretEnvelopeRequest(Guid RecipientDeviceId,
    [property: Required, StringLength(21848, MinimumLength = 4)] string CiphertextBase64);
public sealed record SendSecretMessageRequest(Guid ClientMessageId, Guid SenderDeviceId,
    [property: Required, MinLength(2), MaxLength(2)] SecretEnvelopeRequest[] Envelopes);

public sealed record SecretDeviceView(Guid DeviceId, Guid UserId, int Version, string Label,
    string EncryptionPublicKey, string SigningPublicKey, DateTimeOffset CreatedAt, DateTimeOffset? RevokedAt);
public sealed record SecretConversationView(Guid Id, Guid DirectConversationId, Guid FirstUserId, Guid SecondUserId,
    DateTimeOffset CreatedAt, DateTimeOffset LastActivityAt, long LastSequence);
public sealed record SecretEnvelopeView(Guid RecipientDeviceId, int RecipientKeyVersion, string CiphertextBase64);
public sealed record SecretMessageView(Guid Id, Guid ConversationId, long Sequence, Guid ClientMessageId,
    Guid SenderUserId, Guid SenderDeviceId, int SenderKeyVersion, string SenderSigningPublicKey,
    DateTimeOffset CreatedAt, SecretEnvelopeView Envelope);
public sealed record SecretAttachmentView(Guid Id, long SizeBytes, string Sha256, DateTimeOffset CreatedAt, string DownloadPath);
