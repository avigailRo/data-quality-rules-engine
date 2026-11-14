using System.Text.Json.Serialization;
using DataControls.Api.Auth;
using DataControls.Api.Endpoints;
using DataControls.Application.Abstractions;
using DataControls.Infrastructure;
using DataControls.Infrastructure.SqlServer;
using Microsoft.AspNetCore.Authentication;
using Microsoft.AspNetCore.Diagnostics;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Options;

var builder = WebApplication.CreateBuilder(args);

builder.Services.ConfigureHttpJsonOptions(o =>
{
    o.SerializerOptions.Converters.Add(new JsonStringEnumConverter(System.Text.Json.JsonNamingPolicy.CamelCase));
    o.SerializerOptions.Converters.Add(new UtcDateTimeConverter());
});

builder.Services.AddProblemDetails();
builder.Services
    .AddAuthentication(DevAuthHandler.Scheme)
    .AddScheme<AuthenticationSchemeOptions, DevAuthHandler>(DevAuthHandler.Scheme, _ => { });
builder.Services.AddAuthorizationBuilder()
    .AddPolicy(Policies.Viewer, p => p.RequireRole(Policies.Viewer))
    .AddPolicy(Policies.RuleAuthor, p => p.RequireRole(Policies.RuleAuthor))
    .AddPolicy(Policies.RuleRunner, p => p.RequireRole(Policies.RuleRunner))
    .AddPolicy(Policies.CatalogAdmin, p => p.RequireRole(Policies.CatalogAdmin));

builder.Services.AddDataControls(builder.Configuration);

var app = builder.Build();

// Demo-only settings are announced loudly so they are never mistaken for a production configuration.
app.Logger.LogWarning("Demo authentication is enabled (X-Demo-User header). Replace it with a real identity provider (OIDC / Entra ID) before production.");
if (builder.Configuration["Advisor:ServiceToken"] == "dev-internal-token")
    app.Logger.LogWarning("Advisor:ServiceToken uses the development default. Set it from a secret store (environment / Secret Manager) outside development.");

// Every error becomes RFC 9457 ProblemDetails with a stable code. Technical details are logged, never returned.
app.UseExceptionHandler(errorApp => errorApp.Run(async context =>
{
    var ex = context.Features.Get<IExceptionHandlerFeature>()?.Error;
    var logger = context.RequestServices.GetRequiredService<ILoggerFactory>().CreateLogger("Errors");
    var problem = new ProblemDetails { Instance = context.Request.Path };

    switch (ex)
    {
        case AppException appEx:
            problem.Status = appEx.Status;
            problem.Title = appEx.Message;
            problem.Extensions["code"] = appEx.Code;
            if (appEx.Errors.Count > 0) problem.Extensions["errors"] = appEx.Errors;
            break;
        case BadHttpRequestException bad:
            problem.Status = StatusCodes.Status400BadRequest;
            problem.Title = "הבקשה אינה תקינה.";
            problem.Extensions["code"] = "BAD_REQUEST";
            logger.LogWarning(bad, "Bad request");
            break;
        default:
            problem.Status = StatusCodes.Status500InternalServerError;
            problem.Title = "אירעה שגיאה בלתי צפויה. נסו שוב מאוחר יותר.";
            problem.Extensions["code"] = "INTERNAL_ERROR";
            logger.LogError(ex, "Unhandled error");
            break;
    }
    problem.Extensions["traceId"] = context.TraceIdentifier;
    context.Response.StatusCode = problem.Status ?? 500;
    await context.Response.WriteAsJsonAsync(problem, options: null, contentType: "application/problem+json");
}));

app.UseStatusCodePages();
app.UseAuthentication();
app.UseAuthorization();

app.MapGet("/health/live", () => Results.Ok(new { status = "ok" }));
app.MapGet("/health/ready", async (IOptions<DatabaseOptions> db, CancellationToken ct) =>
{
    try
    {
        await using var conn = new SqlConnection(db.Value.ConnectionString);
        await conn.OpenAsync(ct);
        return Results.Ok(new { status = "ok" });
    }
    catch (SqlException)
    {
        return Results.Problem(title: "Database unavailable", statusCode: 503);
    }
});

app.MapDataControlsApi();

app.Run();

public partial class Program { }

/// <summary>
/// All timestamps are stored in UTC (DATETIME2 has no offset, so Dapper reads them as Unspecified).
/// Writing them with a "Z" lets every client convert to its own local time correctly.
/// </summary>
internal sealed class UtcDateTimeConverter : JsonConverter<DateTime>
{
    public override DateTime Read(ref System.Text.Json.Utf8JsonReader reader, Type typeToConvert, System.Text.Json.JsonSerializerOptions options)
    {
        var d = reader.GetDateTime();
        return d.Kind == DateTimeKind.Unspecified ? DateTime.SpecifyKind(d, DateTimeKind.Utc) : d.ToUniversalTime();
    }

    public override void Write(System.Text.Json.Utf8JsonWriter writer, DateTime value, System.Text.Json.JsonSerializerOptions options) =>
        writer.WriteStringValue(value.Kind == DateTimeKind.Local ? value.ToUniversalTime() : DateTime.SpecifyKind(value, DateTimeKind.Utc));
}
