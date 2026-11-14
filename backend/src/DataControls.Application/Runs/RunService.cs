using System.Diagnostics;
using System.Text.Json;
using DataControls.Application.Abstractions;
using DataControls.Application.Rules;
using DataControls.Domain.Rules.Ast;
using DataControls.Domain.Rules.Binding;
using DataControls.Domain.Rules.Explain;
using Microsoft.Extensions.Logging;

namespace DataControls.Application.Runs;

public sealed record RunExecutionSettings(int MaxStoredViolations = 10_000);

public sealed record ViolationPageDto(
    RunRecord Run, IReadOnlyList<ColumnDto> Columns, IReadOnlyList<ConditionOptionDto> Conditions,
    IReadOnlyList<ViolationDto> Items, int Page, int PageSize, long TotalCount);

/// <summary>A filterable condition in the results screen ("show only violations of condition X").</summary>
public sealed record ConditionOptionDto(string Id, string TextHe);

/// <summary>Separates rule DEFINITION from rule EXECUTION: a run is queued, executed by a worker against a fixed rule version, and its results are stored.</summary>
public sealed class RunService(
    IRuleRepository rules,
    IRunRepository runs,
    IRunQueue queue,
    ICatalogProvider catalog,
    IRuleQueryExecutor executor,
    IClock clock,
    RunExecutionSettings settings,
    ILogger<RunService> logger)
{
    public async Task<RunRecord> StartAsync(Guid ruleId, string user, CancellationToken ct)
    {
        var rule = await rules.GetAsync(ruleId, ct) ?? throw AppException.NotFound("הבקרה");
        if (rule.Status == RuleStatus.Archived)
            throw new AppException("RULE_ARCHIVED", 409, "לא ניתן להריץ בקרה שהועברה לארכיון.");
        if (await runs.HasActiveRunAsync(ruleId, ct))
            throw new AppException("RUN_ALREADY_ACTIVE", 409, "הבקרה כבר רצה כעת. המתינו לסיום ההרצה.");

        var run = new RunRecord
        {
            Id = Guid.NewGuid(),
            RuleId = ruleId,
            RuleVersionNo = rule.CurrentVersion,
            Status = RunStatus.Queued,
            QueuedAt = clock.UtcNow,
            TriggeredBy = user,
            RuleName = rule.Name,
        };
        await runs.InsertAsync(run, ct);
        await queue.EnqueueAsync(run.Id, ct);
        return run;
    }

    public async Task<RunRecord> GetAsync(Guid runId, CancellationToken ct) =>
        await runs.GetAsync(runId, ct) ?? throw AppException.NotFound("ההרצה");

    public Task<IReadOnlyList<RunRecord>> HistoryAsync(Guid ruleId, CancellationToken ct) => runs.ListForRuleAsync(ruleId, 50, ct);

    /// <summary>Called by the background worker.</summary>
    public async Task ExecuteAsync(Guid runId, CancellationToken ct)
    {
        var run = await runs.GetAsync(runId, ct);
        if (run is null || run.Status != RunStatus.Queued) return;

        var started = clock.UtcNow;
        await runs.MarkRunningAsync(runId, started, ct);
        var sw = Stopwatch.StartNew();
        run.StartedAt = started;

        try
        {
            var version = await rules.GetVersionAsync(run.RuleId, run.RuleVersionNo, ct)
                          ?? throw new InvalidOperationException("Rule version not found");

            var bind = new RuleBinder(catalog.Current).Bind(RuleJson.Parse(version.DefinitionJson));
            if (!bind.IsValid)
            {
                Finish(run, RunStatus.Failed, sw, "CATALOG_DRIFT",
                    "הבקרה מפנה לשדות שאינם קיימים עוד בקטלוג: " + string.Join("; ", bind.Errors.Select(e => e.MessageHe)));
                await runs.CompleteAsync(run, ct);
                return;
            }

            var bound = bind.Rule!;
            var result = await executor.ExecuteAsync(bound, settings.MaxStoredViolations, ct);
            var records = result.Rows
                .Select((row, i) => ViolationFactory.ToRecord(ViolationFactory.ToDto(bound, row), i + 1))
                .ToList();
            await runs.SaveViolationsAsync(runId, records, ct);

            run.ViolationCount = result.TotalCount;
            run.StoredCount = records.Count;
            run.IsTruncated = result.TotalCount > records.Count;
            run.SqlHash = result.SqlHash;
            Finish(run, RunStatus.Succeeded, sw, null, null);
        }
        catch (QueryTimeoutException)
        {
            Finish(run, RunStatus.TimedOut, sw, "QUERY_TIMEOUT", "ההרצה חרגה מזמן הריצה המותר.");
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            // Technical details go to the log only, never to the client.
            logger.LogError(ex, "Run {RunId} failed", runId);
            Finish(run, RunStatus.Failed, sw, "EXECUTION_FAILED", "אירעה שגיאה בהרצת הבקרה. פרטים נרשמו ביומן המערכת.");
        }

        await runs.CompleteAsync(run, CancellationToken.None);
    }

    private void Finish(RunRecord run, string status, Stopwatch sw, string? code, string? message)
    {
        run.Status = status;
        run.FinishedAt = clock.UtcNow;
        run.DurationMs = (int)sw.ElapsedMilliseconds;
        run.ErrorCode = code;
        run.ErrorMessage = message;
    }

    public async Task<ViolationPageDto> ViolationsAsync(Guid runId, ViolationQuery q, CancellationToken ct)
    {
        var run = await GetAsync(runId, ct);
        var version = await rules.GetVersionAsync(run.RuleId, run.RuleVersionNo, ct) ?? throw AppException.NotFound("גרסת הבקרה");

        IReadOnlyList<ColumnDto> columns = [];
        IReadOnlyList<ConditionOptionDto> conditions = [];
        var bind = new RuleBinder(catalog.Current).Bind(RuleJson.Parse(version.DefinitionJson));
        if (bind.IsValid)
        {
            columns = ViolationFactory.Columns(bind.Rule!);
            conditions = RootLeaves(bind.Rule!.Condition)
                .Select(n => new ConditionOptionDto(n.Id, RuleDescriber.Describe(n)))
                .ToList();
        }

        var page = await runs.ListViolationsAsync(runId, q, ct);
        var items = page.Items.Select(v => new ViolationDto(
            v.RecordKey,
            v.DisplayLabel,
            JsonSerializer.Deserialize<List<ViolationReason>>(v.ReasonsJson, JsonSerializerOptions.Web) ?? new List<ViolationReason>(),
            JsonSerializer.Deserialize<Dictionary<string, string>>(v.ValuesJson, JsonSerializerOptions.Web) ?? new Dictionary<string, string>())).ToList();

        return new ViolationPageDto(run, columns, conditions, items, q.Page, q.PageSize, page.TotalCount);
    }

    private static IEnumerable<BoundNode> RootLeaves(BoundNode node) => node switch
    {
        BoundGroup { Negate: true } g => new BoundNode[] { g },
        BoundGroup g => g.Children.SelectMany(RootLeaves),
        _ => new[] { node },
    };
}
