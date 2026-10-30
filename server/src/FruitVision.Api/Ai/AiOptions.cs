using Microsoft.Extensions.Options;

namespace FruitVision.Api.Ai;

public sealed class AiOptions
{
    public const long MaxImageBytes = 12L * 1024 * 1024;
    public const long MaxVideoBytes = 80L * 1024 * 1024;
    public bool RunEnabled { get; set; }
    public string PythonPath { get; set; } = "";
    public string WorkerPath { get; set; } = "";
    public string PythonModulePath { get; set; } = "";
    public string PythonExtraModulePath { get; set; } = "";
    public string ModelPath { get; set; } = "";
    public string? ModelName { get; set; }
    public string DataRoot { get; set; } = "";
}

public sealed class AiRuntimeStatus
{
    public AiRuntimeStatus(IOptions<AiOptions> options)
    {
        var value = options.Value;
        ModelName = value.ModelName;
        if (!value.RunEnabled) { Message = "Bộ xử lý AI chưa được bật."; return; }
        var dependencies = string.IsNullOrWhiteSpace(value.PythonExtraModulePath) ? value.PythonModulePath : value.PythonExtraModulePath;
        if (!ExistingAbsoluteFile(value.PythonPath) || !ExistingAbsoluteFile(value.WorkerPath) ||
            !ExistingAbsoluteFile(value.ModelPath) || !Path.IsPathFullyQualified(value.DataRoot) ||
            !Path.IsPathFullyQualified(value.PythonModulePath) ||
            !File.Exists(Path.Combine(value.PythonModulePath, "onnxruntime", "__init__.py")) ||
            !Directory.Exists(Path.Combine(value.PythonModulePath, "onnxruntime", "capi")) ||
            !Directory.EnumerateFiles(Path.Combine(value.PythonModulePath, "onnxruntime", "capi"), "onnxruntime_pybind11_state*").Any() ||
            !Path.IsPathFullyQualified(dependencies) ||
            new[] { "numpy", "PIL", "cv2" }.Any(package => !File.Exists(Path.Combine(dependencies, package, "__init__.py"))))
        {
            Message = "Bộ xử lý hoặc mô hình AI chưa sẵn sàng.";
            return;
        }
        IsReady = true;
    }

    public bool IsReady { get; }
    public string? Message { get; }
    public string? ModelName { get; }
    private static bool ExistingAbsoluteFile(string path) => Path.IsPathFullyQualified(path) && File.Exists(path);
}

public static class AiRegistration
{
    public static IServiceCollection AddFruitVisionAi(this IServiceCollection services, IConfiguration configuration)
    {
        services.Configure<AiOptions>(configuration.GetSection("Ai"));
        services.AddSingleton<AiRuntimeStatus>();
        services.AddSingleton<AiStorage>();
        services.AddSingleton<AiJobControl>();
        services.AddSingleton<AiJobEvents>();
        services.AddHostedService<AiJobWorker>();
        return services;
    }
}
