using Microsoft.AspNetCore.Authorization;
using Microsoft.OpenApi;
using FruitVision.Api.Data;

namespace FruitVision.Api.Infrastructure;

public static class ApiDocumentation
{
    private const string BearerScheme = "SessionBearer";

    public static IServiceCollection AddFruitVisionDocumentation(this IServiceCollection services)
    {
        services.AddOpenApi("v1", options =>
        {
            options.AddSchemaTransformer((schema,context,cancellationToken) =>
            {
                if(context.JsonTypeInfo.Type==typeof(BusinessRole)||context.JsonTypeInfo.Type==typeof(ApprovalState))
                    schema.Type=JsonSchemaType.String;
                return Task.CompletedTask;
            });
            options.AddDocumentTransformer((document, context, cancellationToken) =>
            {
                document.Info.Title = "FruitVision API";
                document.Info.Version = "v1";
                document.Info.Description = "API tài khoản, tương tác và phân tích ảnh/video trên máy chủ FruitVision. Các thao tác ghi thay đổi dữ liệu demo. " +
                    "Đăng ký mặc định Consumer; hoàn tất mã email trước khi có phiên. Đăng nhập bằng mật khẩu và mã email hoặc TOTP đã bật, rồi nhập accessToken vào Authorize. " +
                    "Hồ sơ nâng quyền, chi nhánh và bài đăng có quy trình duyệt riêng. AI chỉ dành cho Producer/Trader được duyệt. " +
                    "Máy chủ kiểm tra vai trò, trạng thái xét duyệt và quyền thành viên trên từng yêu cầu.";
                document.Servers = [new OpenApiServer { Url = "/", Description = "Máy chủ đang mở tài liệu" }];
                document.Components ??= new OpenApiComponents();
                document.Components.SecuritySchemes ??= new Dictionary<string, IOpenApiSecurityScheme>();
                document.Components.SecuritySchemes[BearerScheme] = new OpenApiSecurityScheme
                {
                    Type = SecuritySchemeType.Http,
                    Scheme = "bearer",
                    BearerFormat = "Opaque session token",
                    Description = "Dán chỉ accessToken từ đăng nhập thành công; không nhập tiền tố Bearer. " +
                        "Đây là token phiên opaque. Refresh thay token cũ; đăng xuất hoặc khóa tài khoản sẽ thu hồi phiên."
                };
                return Task.CompletedTask;
            });

            options.AddOperationTransformer((operation, context, cancellationToken) =>
            {
                var metadata = context.Description.ActionDescriptor.EndpointMetadata;
                var authorization = metadata.OfType<IAuthorizeData>().ToArray();
                if (metadata.OfType<IAllowAnonymous>().Any() || authorization.Length == 0)
                    return Task.CompletedTask;

                operation.Security ??= [];
                operation.Security.Add(new OpenApiSecurityRequirement
                {
                    [new OpenApiSecuritySchemeReference(BearerScheme, context.Document)] = []
                });
                var access = authorization.Select(item => item.Policy).ToArray();
                var description = access.Contains("Admin") ? "Cần tài khoản Admin đã duyệt." :
                    access.Contains("Seller") ? "Cần tài khoản Producer hoặc Trader đã duyệt." :
                    access.Contains("Approved") ? "Cần hồ sơ đã duyệt; kiểm tra thêm quyền sở hữu dữ liệu hoặc thành viên hội thoại." :
                    "Cần phiên đăng nhập đang hoạt động.";
                operation.Description = string.IsNullOrWhiteSpace(operation.Description) ? description :
                    operation.Description + "\n\n" + description;
                operation.Responses ??= new OpenApiResponses();
                operation.Responses.TryAdd("401", new OpenApiResponse { Description = "Thiếu token hoặc phiên không còn hợp lệ." });
                if (access.Any(policy => !string.IsNullOrEmpty(policy)))
                    operation.Responses.TryAdd("403", new OpenApiResponse { Description = "Tài khoản chưa đáp ứng vai trò hoặc trạng thái xét duyệt." });
                return Task.CompletedTask;
            });
        });
        return services;
    }
}
