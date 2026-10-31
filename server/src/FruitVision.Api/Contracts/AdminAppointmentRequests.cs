using System.ComponentModel.DataAnnotations;
using System.Text.Json.Serialization;

namespace FruitVision.Api.Contracts;

public sealed record CreateAdminAppointmentRequest(
    [property: JsonRequired] Guid UserId,
    [property: Required, StringLength(1024, MinimumLength = 1)] string Password,
    [property: Required, StringLength(1000, MinimumLength = 3)] string Reason);
