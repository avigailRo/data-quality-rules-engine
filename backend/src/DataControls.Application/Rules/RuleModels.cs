namespace DataControls.Application.Rules;

public static class RuleStatus
{
    public const string Draft = "Draft", Active = "Active", Archived = "Archived";
    public static readonly string[] All = [Draft, Active, Archived];
}

public static class RuleSeverity
{
    public static readonly string[] All = ["Low", "Medium", "High"];
}

public static class RunStatus
{
    public const string Queued = "Queued", Running = "Running", Succeeded = "Succeeded", Failed = "Failed", TimedOut = "TimedOut";
}

/// <summary>Row of dq.Rule (+ last run summary).</summary>
public sealed class RuleRecord
{
    public Guid Id { get; set; }
    public string Name { get; set; } = "";
    public string? Description { get; set; }
    public string RootEntityKey { get; set; } = "";
    public string DefinitionJson { get; set; } = "";
    public string Status { get; set; } = RuleStatus.Draft;
    public string Severity { get; set; } = "Medium";
    public string Origin { get; set; } = "Manual";
    public int CurrentVersion { get; set; }
    public string CreatedBy { get; set; } = "";
    public DateTime CreatedAt { get; set; }
    public string UpdatedBy { get; set; } = "";
    public DateTime UpdatedAt { get; set; }

    public Guid? LastRunId { get; set; }
    public string? LastRunStatus { get; set; }
    public long? LastRunViolationCount { get; set; }
    public DateTime? LastRunFinishedAt { get; set; }
}

public sealed class RuleVersionRecord
{
    public Guid RuleId { get; set; }
    public int VersionNo { get; set; }
    public string Name { get; set; } = "";
    public string DefinitionJson { get; set; } = "";
    public string CreatedBy { get; set; } = "";
    public DateTime CreatedAt { get; set; }
}

public sealed class RunRecord
{
    public Guid Id { get; set; }
    public Guid RuleId { get; set; }
    public int RuleVersionNo { get; set; }
    public string Status { get; set; } = RunStatus.Queued;
    public DateTime QueuedAt { get; set; }
    public DateTime? StartedAt { get; set; }
    public DateTime? FinishedAt { get; set; }
    public int? DurationMs { get; set; }
    public long? ViolationCount { get; set; }
    public int? StoredCount { get; set; }
    public bool IsTruncated { get; set; }
    public string? SqlHash { get; set; }
    public string? ErrorCode { get; set; }
    public string? ErrorMessage { get; set; }
    public string TriggeredBy { get; set; } = "";
    public string? RuleName { get; set; }
}

public sealed class ViolationRecord
{
    public int Seq { get; set; }
    public string RecordKey { get; set; } = "";
    public string DisplayLabel { get; set; } = "";
    public string ReasonsJson { get; set; } = "[]";
    public string FailedConditionIds { get; set; } = ",";
    public string ValuesJson { get; set; } = "{}";
    public string SearchText { get; set; } = "";
}

public sealed record RuleQuery(string? Search, string? Status, string? Entity, int Page, int PageSize);

public sealed record ViolationQuery(string? Search, string? ConditionId, int Page, int PageSize);

public interface IRuleRepository
{
    Task<PagedResultRecord<RuleRecord>> ListAsync(RuleQuery q, CancellationToken ct);
    Task<RuleRecord?> GetAsync(Guid id, CancellationToken ct);
    Task InsertAsync(RuleRecord rule, CancellationToken ct);
    /// <summary>Optimistic concurrency: returns false when CurrentVersion != expectedVersion.</summary>
    Task<bool> UpdateAsync(RuleRecord rule, int expectedVersion, CancellationToken ct);
    Task SetStatusAsync(Guid id, string status, string user, DateTime at, CancellationToken ct);
    Task<IReadOnlyList<RuleVersionRecord>> GetVersionsAsync(Guid ruleId, CancellationToken ct);
    Task<RuleVersionRecord?> GetVersionAsync(Guid ruleId, int versionNo, CancellationToken ct);
}

public interface IRunRepository
{
    Task InsertAsync(RunRecord run, CancellationToken ct);
    Task<RunRecord?> GetAsync(Guid id, CancellationToken ct);
    Task<bool> HasActiveRunAsync(Guid ruleId, CancellationToken ct);
    Task<IReadOnlyList<RunRecord>> ListForRuleAsync(Guid ruleId, int take, CancellationToken ct);
    Task MarkRunningAsync(Guid id, DateTime at, CancellationToken ct);
    Task CompleteAsync(RunRecord run, CancellationToken ct);
    Task SaveViolationsAsync(Guid runId, IReadOnlyList<ViolationRecord> violations, CancellationToken ct);
    Task<PagedResultRecord<ViolationRecord>> ListViolationsAsync(Guid runId, ViolationQuery q, CancellationToken ct);
    Task<int> FailInterruptedRunsAsync(DateTime at, CancellationToken ct);
}

public sealed record PagedResultRecord<T>(IReadOnlyList<T> Items, long TotalCount);
