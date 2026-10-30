namespace FruitVision.Api.Contracts;

// Public identity attached only to messages already authorized by conversation membership.
public sealed record MessageSenderView(Guid Id, string DisplayName, string Role);
