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
    catch(BadHttpRequestException e){await Results.Problem(statusCode:e.StatusCode,title:"Yêu cầu không hợp lệ.").ExecuteAsync(context);}
    catch(DbUpdateException e) when(e.InnerException is PostgresException{SqlState:PostgresErrorCodes.UniqueViolation}) {await Results.Problem(statusCode:409,title:"Dữ liệu đã tồn tại; hãy tải lại và thử lại.").ExecuteAsync(context);}
    catch(Exception e){app.Logger.LogError(e,"Request failed; correlation {Id}",context.TraceIdentifier);if(!context.Response.HasStarted)await Results.Problem(statusCode:500,title:"Không thể xử lý yêu cầu.",extensions:new Dictionary<string,object?>{{"correlationId",context.TraceIdentifier}}).ExecuteAsync(context);}
});
app.UseCors();app.UseAuthentication();app.UseRateLimiter();app.UseDefaultFiles();app.UseStaticFiles();app.UseAuthorization();
app.MapGet("/health/live",()=>Results.Ok(new{status="live"}));
app.MapGet("/health/ready",async(AppDbContext db,AiRuntimeStatus ai)=>await db.Database.CanConnectAsync()?Results.Ok(new{status="ready",scope="accounts-posts-community-market-and-server-ai",aiReady=ai.IsReady}):Results.StatusCode(503));
app.MapGet("/api/v1/system/capabilities",(AiRuntimeStatus ai)=>Results.Ok(new{aiExecutionLocation="server",aiReady=ai.IsReady,aiScope="fruit-detection-source-stages-and-counting",biometricVerification="planned-device-bound-passkey-not-client-boolean",mfa="TOTP",roles=new[]{"Admin","Producer","Trader","Consumer"},tradeFlowReady=false,
    postModerationReady=true,postConversationsReady=true,communityGroupsReady=true,regionalMarketReferenceReady=true,marketPricePredictionReady=false,stockAndOrdersReady=false}));
app.MapAuth();app.MapAccounts();app.MapInteractions();app.MapFruitVisionAi();app.MapMobileUpdates();
app.MapHub<FruitHub>("/hubs/fruitvision",o=>{o.CloseOnAuthenticationExpiration=true;o.Transports=HttpTransportType.WebSockets|HttpTransportType.LongPolling;});
app.MapOpenApi();
app.Run();
public partial class Program { }
