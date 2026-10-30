using System.ComponentModel.DataAnnotations;
using System.Globalization;
using System.Text;

namespace FruitVision.Api.Infrastructure;

public sealed class InputFilter : IEndpointFilter
{
    public async ValueTask<object?> InvokeAsync(EndpointFilterInvocationContext context, EndpointFilterDelegate next)
    {
        foreach (var arg in context.Arguments)
        {
            if (arg is null || arg.GetType().Namespace != "FruitVision.Api.Contracts") continue;
            var results = new List<ValidationResult>();
            if (!Validator.TryValidateObject(arg, new ValidationContext(arg), results, true))
                return Results.ValidationProblem(results.GroupBy(x => x.MemberNames.FirstOrDefault() ?? "input")
                    .ToDictionary(x => x.Key, x => x.Select(v => v.ErrorMessage ?? "Dữ liệu không hợp lệ.").ToArray()));
        }
        return await next(context);
    }
}

public static class Input
{
    public static string Text(string value) => value.Trim().Normalize(NormalizationForm.FormC);
    public static bool Safe(string value, bool multiline = false) => value.All(c =>
        !char.IsControl(c) || (multiline && c is '\n' or '\r' or '\t'));
    public static IResult Invalid(string detail) => Results.Problem(statusCode: 400, title: "Dữ liệu không hợp lệ", detail: detail);
    public static IResult Denied() => Results.Problem(statusCode: 403, title: "Không có quyền thực hiện thao tác này.");
    public static bool Page(int? requested, out int size)
    {
        size = requested ?? 20;
        return size is >= 1 and <= 50;
    }
}
