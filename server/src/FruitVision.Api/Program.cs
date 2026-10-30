using System.Text.Json.Serialization;
using System.Threading.RateLimiting;
using System.Net;
using FruitVision.Api.Auth;
using FruitVision.Api.Ai;
using FruitVision.Api.Data;
using FruitVision.Api.Features;
using FruitVision.Api.Infrastructure;
using FruitVision.Api.Realtime;
using Microsoft.AspNetCore.Authentication;
using Microsoft.AspNetCore.Identity;
using Microsoft.AspNetCore.HttpOverrides;
using Microsoft.AspNetCore.Http.Connections;
using Microsoft.AspNetCore.Http.Features;
using Microsoft.AspNetCore.DataProtection;
using Microsoft.EntityFrameworkCore;
using Npgsql;

var builder=WebApplication.CreateBuilder(args);
var localConfig=Environment.GetEnvironmentVariable("FRUITVISION_CONFIG");
if(!string.IsNullOrWhiteSpace(localConfig))builder.Configuration.AddJsonFile(localConfig,false,false).AddEnvironmentVariables();
builder.WebHost.ConfigureKestrel(o=>{o.Limits.MaxRequestBodySize=32768;o.Limits.RequestHeadersTimeout=TimeSpan.FromSeconds(10);});
builder.Services.Configure<ForwardedHeadersOptions>(o=>{
    o.ForwardedHeaders=ForwardedHeaders.XForwardedFor|ForwardedHeaders.XForwardedProto;
    o.KnownIPNetworks.Clear();o.KnownProxies.Clear();
    o.KnownProxies.Add(IPAddress.Loopback);o.KnownProxies.Add(IPAddress.IPv6Loopback);o.ForwardLimit=1;
});
builder.Services.ConfigureHttpJsonOptions(o=>{
    o.SerializerOptions.UnmappedMemberHandling=JsonUnmappedMemberHandling.Disallow;
    o.SerializerOptions.PropertyNameCaseInsensitive=false;
    o.SerializerOptions.Converters.Add(new JsonStringEnumConverter(allowIntegerValues:false));
    o.SerializerOptions.MaxDepth=16;
});
builder.Services.AddDbContext<AppDbContext>((services,o)=>o.UseNpgsql(services.GetRequiredService<IConfiguration>()
    .GetConnectionString("Database")??throw new InvalidOperationException("Configure ConnectionStrings:Database outside source control.")).EnableDetailedErrors(false));
builder.Services.AddIdentityCore<AppUser>(o=>{
    o.User.RequireUniqueEmail=true;
    o.Password.RequiredLength=12;o.Password.RequireDigit=true;o.Password.RequireLowercase=true;o.Password.RequireUppercase=true;o.Password.RequireNonAlphanumeric=true;
    o.Lockout.MaxFailedAccessAttempts=5;o.Lockout.DefaultLockoutTimeSpan=TimeSpan.FromMinutes(15);o.Lockout.AllowedForNewUsers=true;
}).AddEntityFrameworkStores<AppDbContext>().AddDefaultTokenProviders();
builder.Services.Configure<PasswordHasherOptions>(o=>o.IterationCount=210000);
builder.Services.AddAuthentication("Session").AddScheme<AuthenticationSchemeOptions,SessionAuthenticationHandler>("Session",_=>{});
builder.Services.AddAuthorization(o=>{
    o.AddPolicy("Approved",p=>p.RequireAuthenticatedUser().RequireClaim("approval","Approved"));
    o.AddPolicy("Admin",p=>p.RequireAuthenticatedUser().RequireRole("Admin").RequireClaim("approval","Approved"));
    o.AddPolicy("Seller",p=>p.RequireAuthenticatedUser().RequireRole("Producer","Trader").RequireClaim("approval","Approved"));
});
builder.Services.AddCors(o=>o.AddDefaultPolicy(p=>{
    var origins=builder.Configuration.GetSection("Cors:Origins").Get<string[]>()??[];
    if(origins.Length>0)p.WithOrigins(origins).AllowAnyHeader().AllowAnyMethod().AllowCredentials();
}));
builder.Services.AddRateLimiter(o=>{
    o.RejectionStatusCode=429;
    o.GlobalLimiter=PartitionedRateLimiter.Create<HttpContext,string>(h=>RateLimitPartition.GetFixedWindowLimiter(
        h.User.Identity?.IsAuthenticated==true ? "user:"+h.User.UserId().ToString("N") : "ip:"+(h.Connection.RemoteIpAddress?.ToString()??"local"),
        _=>new FixedWindowRateLimiterOptions{PermitLimit=builder.Configuration.GetValue("Limits:RequestsPerMinute",120),Window=TimeSpan.FromMinutes(1),QueueLimit=0}));
    o.AddPolicy("auth",h=>RateLimitPartition.GetFixedWindowLimiter(h.Connection.RemoteIpAddress?.ToString()??"local",
        _=>new FixedWindowRateLimiterOptions{PermitLimit=builder.Configuration.GetValue("Limits:AuthPerMinute",30),Window=TimeSpan.FromMinutes(1),QueueLimit=0}));
    o.OnRejected=async(c,t)=>{c.HttpContext.Response.Headers.RetryAfter="60";await c.HttpContext.Response.WriteAsJsonAsync(new{title="Quá nhiều yêu cầu. Vui lòng thử lại sau.",status=429},t);};
});
builder.Services.AddSignalR(o=>{o.MaximumReceiveMessageSize=8192;o.MaximumParallelInvocationsPerClient=1;o.EnableDetailedErrors=false;});
builder.Services.AddSingleton<SessionConnections>();builder.Services.AddHostedService<OutboxDispatcher>();
builder.Services.AddFruitVisionAi(builder.Configuration);
builder.Services.AddLocationDirectory();
builder.Services.AddRoleApplications(builder.Configuration);
builder.Services.AddSecretMessaging(builder.Configuration);
builder.Services.AddNormalMedia(builder.Configuration);
builder.Services.Configure<EmailOtpOptions>(builder.Configuration.GetSection("EmailOtp"));
builder.Services.AddHttpClient(AppsScriptOtpMailer.ClientName, c => c.Timeout = Timeout.InfiniteTimeSpan)
    .ConfigurePrimaryHttpMessageHandler(() => new SocketsHttpHandler { AllowAutoRedirect = false, ConnectTimeout = TimeSpan.FromSeconds(5) });
builder.Services.AddSingleton<IEmailOtpMailer,AppsScriptOtpMailer>();
builder.Services.AddSingleton<EmailOtpService>();
builder.Services.AddFaceAuth(builder.Configuration);
var protection=builder.Services.AddDataProtection().SetApplicationName("FruitVision.Security.v1");
var protectionPath=builder.Configuration["DataProtection:RootPath"];
if(!string.IsNullOrWhiteSpace(protectionPath)) {
    if(!Path.IsPathFullyQualified(protectionPath))throw new InvalidOperationException("DataProtection requires an absolute private path.");
    protection.PersistKeysToFileSystem(new DirectoryInfo(protectionPath));
    if(OperatingSystem.IsWindows())protection.ProtectKeysWithDpapi();
}
builder.Services.Configure<MobileUpdateOptions>(builder.Configuration.GetSection("MobileUpdates"));
builder.Services.AddSingleton<MobileUpdateService>();
builder.Services.AddFruitVisionDocumentation();builder.Services.AddProblemDetails();
builder.Logging.AddFilter("Microsoft.EntityFrameworkCore.Database.Command",LogLevel.Warning);
builder.Logging.AddFilter("Microsoft.AspNetCore.Hosting.Diagnostics",LogLevel.Warning);
builder.Logging.AddFilter("Microsoft.AspNetCore.Http.Connections",LogLevel.Warning);
builder.Logging.AddFilter("Microsoft.AspNetCore.SignalR",LogLevel.Warning);
var app=builder.Build();
if(args.Contains("--migrate")||builder.Configuration.GetValue<bool>("Database:AutoMigrate")) {
    if(app.Environment.IsProduction()&&!args.Contains("--migrate"))throw new InvalidOperationException("Run explicit migrations before Production startup.");
    using var scope=app.Services.CreateScope();await scope.ServiceProvider.GetRequiredService<AppDbContext>().Database.MigrateAsync();
}
if(args.Contains("--migrate"))return;
await DemoSeed.Run(app.Services,builder.Configuration,app.Environment);
app.UseForwardedHeaders();
app.Use(async(context,next)=>{
    context.Response.Headers.XContentTypeOptions="nosniff";context.Response.Headers.CacheControl="no-store";
    context.Response.Headers.XFrameOptions="DENY";
    context.Response.Headers["Referrer-Policy"]="no-referrer";
    context.Response.Headers.ContentSecurityPolicy="default-src 'self'; script-src 'self'; style-src 'self'; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'";
    context.Response.Headers["X-Correlation-ID"]=context.TraceIdentifier;
    try{await next(context);}
    catch(LocationSelectionException e){await Input.Invalid(e.Message).ExecuteAsync(context);}
    catch(MediaQuotaException e){await Results.Problem(statusCode:e.Status,title:e.Message).ExecuteAsync(context);}
    catch(LocationDirectoryUnavailableException){await Results.Problem(statusCode:503,title:"Danh mục địa điểm chưa sẵn sàng. Vui lòng thử lại sau.").ExecuteAsync(context);}
    catch(BadHttpRequestException e){await Results.Problem(statusCode:e.StatusCode,title:"Yêu cầu không hợp lệ.").ExecuteAsync(context);}
    catch(DbUpdateException e) when(e.InnerException is PostgresException{SqlState:PostgresErrorCodes.UniqueViolation}) {await Results.Problem(statusCode:409,title:"Dữ liệu đã tồn tại; hãy tải lại và thử lại.").ExecuteAsync(context);}
    catch(Exception e){app.Logger.LogError(e,"Request failed; correlation {Id}",context.TraceIdentifier);if(!context.Response.HasStarted)await Results.Problem(statusCode:500,title:"Không thể xử lý yêu cầu.",extensions:new Dictionary<string,object?>{{"correlationId",context.TraceIdentifier}}).ExecuteAsync(context);}
});
app.UseStatusCodePages(async status => {
    var http=status.HttpContext;
    if(!http.Request.Path.StartsWithSegments("/api/v1") || HttpMethods.IsHead(http.Request.Method))return;
    var code=http.Response.StatusCode;
    await http.Response.WriteAsJsonAsync(new {status=code,title=code switch {
        400=>"Dữ liệu không đúng định dạng hoặc có trường không được chấp nhận.",
        401=>"Phiên đăng nhập hoặc thông tin xác thực không hợp lệ.",
        403=>"Tài khoản không có quyền thực hiện thao tác này.",
        404=>"Không tìm thấy dữ liệu hoặc bạn không được phép truy cập.",
        _=>"Không thể thực hiện yêu cầu. Vui lòng thử lại."},correlationId=http.TraceIdentifier});
});
app.Use(async(context,next)=>{
    if(HttpMethods.IsPost(context.Request.Method) && context.Request.Path.Value is "/api/v1/auth/face/login" or "/api/v1/auth/face/enroll") {
        var maximum=context.Features.Get<IHttpMaxRequestBodySizeFeature>();
        if(maximum is {IsReadOnly:false})maximum.MaxRequestBodySize=3L*1024*1024;
    }
    if(HttpMethods.IsPost(context.Request.Method)) {
        var parts=(context.Request.Path.Value??"").Split('/',StringSplitOptions.RemoveEmptyEntries);
        if(parts.Length==6 && parts[0]=="api" && parts[1]=="v1" && parts[2]=="secret" && parts[3]=="conversations" && Guid.TryParse(parts[4],out _) && parts[5]=="messages") {
            var maximum=context.Features.Get<IHttpMaxRequestBodySizeFeature>();
            if(maximum is {IsReadOnly:false})maximum.MaxRequestBodySize=64*1024;
        }
    }
    await next(context);
});
app.UseCors();app.UseAuthentication();app.UseRateLimiter();app.UseDefaultFiles();app.UseStaticFiles();app.UseAuthorization();
app.MapGet("/health/live",()=>Results.Ok(new{status="live"}));
app.MapGet("/health/ready",async(AppDbContext db,AiRuntimeStatus ai)=>await db.Database.CanConnectAsync()?Results.Ok(new{status="ready",scope="accounts-posts-community-market-and-server-ai",aiReady=ai.IsReady}):Results.StatusCode(503));
app.MapGet("/api/v1/system/capabilities",(AiRuntimeStatus ai,EmailOtpService otp,IFaceEngine face)=>Results.Ok(new{aiExecutionLocation="server",aiReady=ai.IsReady,aiScope="fruit-detection-source-stages-and-counting",biometricVerification="device-bound-strong-biometric-rsa-challenge",mfa="Email OTP and optional TOTP",emailOtpReady=otp.IsReady,faceReady=face.IsReady&&otp.IsReady,faceLivenessVerified=false,roles=new[]{"Admin","Producer","Trader","Consumer"},tradeFlowReady=false,
    roleApplicationsReady=true,communityArticlesReady=true,branchModerationReady=true,apiLocationSelectionReady=true,
    postModerationReady=true,postConversationsReady=true,communityGroupsReady=true,regionalMarketReferenceReady=true,marketPricePredictionReady=false,stockAndOrdersReady=false}));
app.MapAuth();app.MapAccounts();app.MapInteractions();app.MapFruitVisionAi();app.MapMobileUpdates();
app.MapLocations();app.MapRoleApplications();app.MapPublishing();
app.MapEmailOtp();app.MapAiInsights();
app.MapDeviceBiometrics();
app.MapFaceAuth();
app.MapSecretMessaging();
app.MapLearning();
app.MapNormalMedia();
app.MapArticleContact();
app.MapHub<FruitHub>("/hubs/fruitvision",o=>{o.CloseOnAuthenticationExpiration=true;o.Transports=HttpTransportType.WebSockets|HttpTransportType.LongPolling;});
app.MapOpenApi();
app.Run();
public partial class Program { }
