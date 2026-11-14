using DataControls.Domain.Catalog;
using DataControls.Domain.Rules.Binding;

namespace DataControls.Application.Abstractions;

/// <summary>Application error with a stable code, HTTP status and Hebrew message (mapped to ProblemDetails by the API).</summary>
public sealed class AppException(string code, int status, string messageHe, IReadOnlyList<ValidationError>? errors = null)
    : Exception(messageHe)
{
    public string Code { get; } = code;
    public int Status { get; } = status;
    public IReadOnlyList<ValidationError> Errors { get; } = errors ?? [];

    public static AppException NotFound(string what) => new("NOT_FOUND", 404, $"{what} לא נמצא/ה.");
    public static AppException Validation(IReadOnlyList<ValidationError> errors) =>
        new("RULE_VALIDATION_FAILED", 400, "הגדרת הבקרה אינה תקינה.", errors);
}

public sealed class QueryTimeoutException() : Exception("The control query exceeded the configured timeout.");

public sealed record PagedResult<T>(IReadOnlyList<T> Items, int Page, int PageSize, long TotalCount);

public interface ICatalogProvider
{
    BusinessCatalog Current { get; }
    Task ReloadAsync(CancellationToken ct = default);
}

public sealed record CatalogIssue(string EntityKey, string? FieldKey, string MessageHe);

public interface ICatalogVerifier
{
    Task<IReadOnlyList<CatalogIssue>> VerifyAsync(BusinessCatalog catalog, CancellationToken ct = default);
}

public sealed class ExecutedRow
{
    public required string Key { get; init; }
    public required object? Label { get; init; }
    public required IReadOnlyDictionary<string, bool> Flags { get; init; }
    public required IReadOnlyDictionary<string, object?> Values { get; init; }
}

public sealed class RuleExecutionResult
{
    public required long TotalCount { get; init; }
    public required IReadOnlyList<ExecutedRow> Rows { get; init; }
    public required string SqlHash { get; init; }
}

public sealed record CompiledSqlView(string Sql, IReadOnlyList<string> Parameters);

/// <summary>Compiles a bound rule to SQL and executes it with least privilege. The only component that knows SQL.</summary>
public interface IRuleQueryExecutor
{
    Task<RuleExecutionResult> ExecuteAsync(BoundRule rule, int maxRows, CancellationToken ct);
    CompiledSqlView Explain(BoundRule rule, int maxRows);
}

public interface IRunQueue
{
    ValueTask EnqueueAsync(Guid runId, CancellationToken ct = default);
    IAsyncEnumerable<Guid> ReadAllAsync(CancellationToken ct);
}

public interface IClock
{
    DateTime UtcNow { get; }
}
