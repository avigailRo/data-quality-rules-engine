using DataControls.Api.Auth;
using DataControls.Application.Abstractions;
using DataControls.Application.Rules;
using DataControls.Application.Runs;
using DataControls.Application.Suggestions;
using Microsoft.AspNetCore.Mvc;

namespace DataControls.Api.Endpoints;

public static class ApiEndpoints
{
    public static void MapDataControlsApi(this WebApplication app)
    {
        var api = app.MapGroup("/api/v1");
        MapCatalog(api);
        MapRules(api);
        MapRuns(api);
        MapAi(api);
    }

    private static (int Page, int PageSize) Paging(int? page, int? pageSize) =>
        (Math.Max(page ?? 1, 1), Math.Clamp(pageSize ?? 20, 1, 100));

    private static void MapCatalog(RouteGroupBuilder api)
    {
        var g = api.MapGroup("/catalog").RequireAuthorization(Policies.Viewer).WithTags("Catalog");

        g.MapGet("/entities", (ICatalogProvider catalog) =>
            Results.Ok(catalog.Current.Entities.Values.Select(DtoMapper.ToDto)));

        g.MapGet("/entities/{key}", (string key, ICatalogProvider catalog) =>
            catalog.Current.FindEntity(key) is { } e ? Results.Ok(DtoMapper.ToDto(e)) : throw AppException.NotFound("הישות"));

        g.MapGet("/operators", () => Results.Ok(DtoMapper.Operators()));

        var admin = api.MapGroup("/admin/catalog").RequireAuthorization(Policies.CatalogAdmin).WithTags("Catalog admin");

        admin.MapPost("/verify", async (ICatalogProvider catalog, ICatalogVerifier verifier, CancellationToken ct) =>
        {
            await catalog.ReloadAsync(ct);
            var issues = await verifier.VerifyAsync(catalog.Current, ct);
            return Results.Ok(new { valid = issues.Count == 0, issues });
        });
    }

    private static void MapRules(RouteGroupBuilder api)
    {
        var g = api.MapGroup("/rules").WithTags("Rules");

        g.MapGet("", async (string? search, string? status, string? entity, int? page, int? pageSize,
            RuleService rules, ICatalogProvider catalog, CancellationToken ct) =>
        {
            var (p, ps) = Paging(page, pageSize);
            var result = await rules.ListAsync(new RuleQuery(search, status, entity, p, ps), ct);
            var items = result.Items.Select(r => DtoMapper.ToDto(r, catalog.Current, rules.SummaryOf(r))).ToList();
            return Results.Ok(new PagedResult<RuleDto>(items, p, ps, result.TotalCount));
        }).RequireAuthorization(Policies.Viewer);

        g.MapGet("/{id:guid}", async (Guid id, HttpContext http, RuleService rules, ICatalogProvider catalog, CancellationToken ct) =>
        {
            var r = await rules.GetAsync(id, ct);
            http.Response.Headers.ETag = $"\"{r.CurrentVersion}\"";
            return Results.Ok(DtoMapper.ToDto(r, catalog.Current, rules.SummaryOf(r)));
        }).RequireAuthorization(Policies.Viewer);

        g.MapGet("/{id:guid}/versions", async (Guid id, RuleService rules, CancellationToken ct) =>
            Results.Ok((await rules.VersionsAsync(id, ct)).Select(v => new RuleVersionDto(v.VersionNo, v.Name, v.CreatedBy, v.CreatedAt))))
            .RequireAuthorization(Policies.Viewer);

        g.MapPost("", async (SaveRuleRequest req, HttpContext http, RuleService rules, ICatalogProvider catalog, CancellationToken ct) =>
        {
            var r = await rules.CreateAsync(req, http.User.UserId(), "Manual", ct);
            http.Response.Headers.ETag = $"\"{r.CurrentVersion}\"";
            return Results.Created($"/api/v1/rules/{r.Id}", DtoMapper.ToDto(r, catalog.Current, rules.SummaryOf(r)));
        }).RequireAuthorization(Policies.RuleAuthor);

        g.MapPut("/{id:guid}", async (Guid id, SaveRuleRequest req, [FromHeader(Name = "If-Match")] string? ifMatch,
            HttpContext http, RuleService rules, ICatalogProvider catalog, CancellationToken ct) =>
        {
            if (!int.TryParse(ifMatch?.Trim('"', ' ', 'W', '/'), out var expected))
                throw new AppException("PRECONDITION_REQUIRED", 428, "חסרה כותרת If-Match עם גרסת הבקרה.");
            var r = await rules.UpdateAsync(id, req, expected, http.User.UserId(), ct);
            http.Response.Headers.ETag = $"\"{r.CurrentVersion}\"";
            return Results.Ok(DtoMapper.ToDto(r, catalog.Current, rules.SummaryOf(r)));
        }).RequireAuthorization(Policies.RuleAuthor);

        g.MapPost("/{id:guid}/duplicate", async (Guid id, HttpContext http, RuleService rules, ICatalogProvider catalog, CancellationToken ct) =>
        {
            var r = await rules.DuplicateAsync(id, http.User.UserId(), ct);
            return Results.Created($"/api/v1/rules/{r.Id}", DtoMapper.ToDto(r, catalog.Current, rules.SummaryOf(r)));
        }).RequireAuthorization(Policies.RuleAuthor);

        g.MapPost("/{id:guid}/archive", async (Guid id, HttpContext http, RuleService rules, CancellationToken ct) =>
        {
            await rules.ArchiveAsync(id, http.User.UserId(), ct);
            return Results.NoContent();
        }).RequireAuthorization(Policies.RuleAuthor);

        g.MapPost("/validate", (DefinitionBody body, RuleService rules) => Results.Ok(rules.Validate(body.Definition)))
            .RequireAuthorization(Policies.Viewer);

        g.MapPost("/preview", async (DefinitionBody body, RuleService rules, CancellationToken ct) =>
            Results.Ok(await rules.PreviewAsync(body.Definition, ct)))
            .RequireAuthorization(Policies.RuleAuthor);

        g.MapGet("/{id:guid}/sql", async (Guid id, RuleService rules, CancellationToken ct) =>
            Results.Ok(await rules.GetSqlAsync(id, ct)))
            .RequireAuthorization(Policies.CatalogAdmin);
    }

    private static void MapRuns(RouteGroupBuilder api)
    {
        api.MapPost("/rules/{id:guid}/runs", async (Guid id, HttpContext http, RunService runs, CancellationToken ct) =>
        {
            var run = await runs.StartAsync(id, http.User.UserId(), ct);
            return Results.Accepted($"/api/v1/runs/{run.Id}", run);
        }).RequireAuthorization(Policies.RuleRunner).WithTags("Runs");

        api.MapGet("/rules/{id:guid}/runs", async (Guid id, RunService runs, CancellationToken ct) =>
            Results.Ok(await runs.HistoryAsync(id, ct)))
            .RequireAuthorization(Policies.Viewer).WithTags("Runs");

        api.MapGet("/runs/{runId:guid}", async (Guid runId, RunService runs, CancellationToken ct) =>
            Results.Ok(await runs.GetAsync(runId, ct)))
            .RequireAuthorization(Policies.Viewer).WithTags("Runs");

        api.MapGet("/runs/{runId:guid}/violations", async (Guid runId, string? search, string? conditionId, int? page, int? pageSize,
            RunService runs, CancellationToken ct) =>
        {
            var (p, ps) = Paging(page, pageSize);
            return Results.Ok(await runs.ViolationsAsync(runId, new ViolationQuery(search, conditionId, p, ps), ct));
        }).RequireAuthorization(Policies.Viewer).WithTags("Runs");
    }

    private static void MapAi(RouteGroupBuilder api)
    {
        var g = api.MapGroup("/ai").WithTags("AI suggestions");

        g.MapGet("/status", async (SuggestionService s, CancellationToken ct) => Results.Ok(await s.StatusAsync(ct)))
            .RequireAuthorization(Policies.Viewer);

        g.MapPost("/suggestions/generate", async (GenerateBody? body, SuggestionService s, CancellationToken ct) =>
            Results.Ok(await s.GenerateAsync(body?.MaxSuggestions ?? 8, ct)))
            .RequireAuthorization(Policies.RuleAuthor);

        g.MapGet("/suggestions", async (Guid? batchId, string? status, SuggestionService s, CancellationToken ct) =>
            Results.Ok(await s.ListAsync(batchId, status, ct)))
            .RequireAuthorization(Policies.RuleAuthor);

        g.MapPost("/suggestions/{id:guid}/accept", async (Guid id, AcceptSuggestionRequest req, HttpContext http,
            SuggestionService s, RuleService rules, ICatalogProvider catalog, CancellationToken ct) =>
        {
            var r = await s.AcceptAsync(id, req, http.User.UserId(), ct);
            return Results.Ok(DtoMapper.ToDto(r, catalog.Current, rules.SummaryOf(r)));
        }).RequireAuthorization(Policies.RuleAuthor);

        g.MapPost("/suggestions/{id:guid}/reject", async (Guid id, HttpContext http, SuggestionService s, CancellationToken ct) =>
        {
            await s.RejectAsync(id, http.User.UserId(), ct);
            return Results.NoContent();
        }).RequireAuthorization(Policies.RuleAuthor);
    }
}

public sealed record DefinitionBody(System.Text.Json.JsonElement Definition);

public sealed record GenerateBody(int? MaxSuggestions);
