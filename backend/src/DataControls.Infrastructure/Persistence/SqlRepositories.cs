using System.Data;
using Dapper;
using DataControls.Application.Rules;
using DataControls.Application.Suggestions;
using DataControls.Infrastructure.SqlServer;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Options;

namespace DataControls.Infrastructure.Persistence;

public abstract class SqlRepositoryBase(IOptions<DatabaseOptions> options)
{
    protected SqlConnection Open() => new(options.Value.ConnectionString);

    /// <summary>Escapes LIKE wildcards so user search text is matched literally.</summary>
    protected static string LikeContains(string text) =>
        "%" + text.Replace("[", "[[]").Replace("%", "[%]").Replace("_", "[_]") + "%";
}

public sealed class SqlRuleRepository(IOptions<DatabaseOptions> options) : SqlRepositoryBase(options), IRuleRepository
{
    private const string SelectRule = @"
        SELECT r.Id, r.Name, r.Description, r.RootEntityKey, r.DefinitionJson, r.Status, r.Severity, r.Origin, r.CurrentVersion,
               r.CreatedBy, r.CreatedAt, r.UpdatedBy, r.UpdatedAt,
               lr.Id AS LastRunId, lr.Status AS LastRunStatus, lr.ViolationCount AS LastRunViolationCount, lr.FinishedAt AS LastRunFinishedAt
        FROM dq.[Rule] r
        OUTER APPLY (SELECT TOP (1) x.Id, x.Status, x.ViolationCount, x.FinishedAt FROM dq.RuleRun x WHERE x.RuleId = r.Id ORDER BY x.QueuedAt DESC) lr";

    public async Task<PagedResultRecord<RuleRecord>> ListAsync(RuleQuery q, CancellationToken ct)
    {
        var where = new List<string>();
        var p = new DynamicParameters();
        if (!string.IsNullOrWhiteSpace(q.Search)) { where.Add("(r.Name LIKE @search OR r.Description LIKE @search)"); p.Add("search", LikeContains(q.Search.Trim())); }
        if (!string.IsNullOrWhiteSpace(q.Status)) { where.Add("r.Status = @status"); p.Add("status", q.Status); }
        else where.Add("r.Status <> N'Archived'");
        if (!string.IsNullOrWhiteSpace(q.Entity)) { where.Add("r.RootEntityKey = @entity"); p.Add("entity", q.Entity); }
        var whereSql = where.Count > 0 ? " WHERE " + string.Join(" AND ", where) : "";
        p.Add("skip", (q.Page - 1) * q.PageSize);
        p.Add("take", q.PageSize);

        await using var conn = Open();
        var total = await conn.ExecuteScalarAsync<long>(new CommandDefinition($"SELECT COUNT_BIG(*) FROM dq.[Rule] r{whereSql}", p, cancellationToken: ct));
        var items = await conn.QueryAsync<RuleRecord>(new CommandDefinition(
            $"{SelectRule}{whereSql} ORDER BY r.UpdatedAt DESC, r.Id OFFSET @skip ROWS FETCH NEXT @take ROWS ONLY", p, cancellationToken: ct));
        return new PagedResultRecord<RuleRecord>(items.ToList(), total);
    }

    public async Task<RuleRecord?> GetAsync(Guid id, CancellationToken ct)
    {
        await using var conn = Open();
        return await conn.QuerySingleOrDefaultAsync<RuleRecord>(new CommandDefinition($"{SelectRule} WHERE r.Id = @id", new { id }, cancellationToken: ct));
    }

    public async Task InsertAsync(RuleRecord r, CancellationToken ct)
    {
        await using var conn = Open();
        await conn.OpenAsync(ct);
        await using var tx = await conn.BeginTransactionAsync(ct);
        await conn.ExecuteAsync(new CommandDefinition(@"
            INSERT INTO dq.[Rule] (Id, Name, Description, RootEntityKey, DefinitionJson, SchemaVersion, Status, Severity, Origin, CurrentVersion, CreatedBy, CreatedAt, UpdatedBy, UpdatedAt)
            VALUES (@Id, @Name, @Description, @RootEntityKey, @DefinitionJson, 1, @Status, @Severity, @Origin, @CurrentVersion, @CreatedBy, @CreatedAt, @UpdatedBy, @UpdatedAt);
            INSERT INTO dq.RuleVersion (RuleId, VersionNo, Name, DefinitionJson, CreatedBy, CreatedAt)
            VALUES (@Id, @CurrentVersion, @Name, @DefinitionJson, @CreatedBy, @CreatedAt);", r, tx, cancellationToken: ct));
        await tx.CommitAsync(ct);
    }

    public async Task<bool> UpdateAsync(RuleRecord r, int expectedVersion, CancellationToken ct)
    {
        await using var conn = Open();
        await conn.OpenAsync(ct);
        await using var tx = await conn.BeginTransactionAsync(ct);
        var affected = await conn.ExecuteAsync(new CommandDefinition(@"
            UPDATE dq.[Rule] SET Name = @Name, Description = @Description, RootEntityKey = @RootEntityKey, DefinitionJson = @DefinitionJson,
                   Status = @Status, Severity = @Severity, CurrentVersion = @CurrentVersion, UpdatedBy = @UpdatedBy, UpdatedAt = @UpdatedAt
            WHERE Id = @Id AND CurrentVersion = @expectedVersion;",
            new { r.Name, r.Description, r.RootEntityKey, r.DefinitionJson, r.Status, r.Severity, r.CurrentVersion, r.UpdatedBy, r.UpdatedAt, r.Id, expectedVersion },
            tx, cancellationToken: ct));
        if (affected == 0) { await tx.RollbackAsync(ct); return false; }

        await conn.ExecuteAsync(new CommandDefinition(@"
            INSERT INTO dq.RuleVersion (RuleId, VersionNo, Name, DefinitionJson, CreatedBy, CreatedAt)
            VALUES (@Id, @CurrentVersion, @Name, @DefinitionJson, @UpdatedBy, @UpdatedAt);", r, tx, cancellationToken: ct));
        await tx.CommitAsync(ct);
        return true;
    }

    public async Task SetStatusAsync(Guid id, string status, string user, DateTime at, CancellationToken ct)
    {
        await using var conn = Open();
        await conn.ExecuteAsync(new CommandDefinition(
            "UPDATE dq.[Rule] SET Status = @status, UpdatedBy = @user, UpdatedAt = @at WHERE Id = @id", new { id, status, user, at }, cancellationToken: ct));
    }

    public async Task<IReadOnlyList<RuleVersionRecord>> GetVersionsAsync(Guid ruleId, CancellationToken ct)
    {
        await using var conn = Open();
        return (await conn.QueryAsync<RuleVersionRecord>(new CommandDefinition(
            "SELECT RuleId, VersionNo, Name, DefinitionJson, CreatedBy, CreatedAt FROM dq.RuleVersion WHERE RuleId = @ruleId ORDER BY VersionNo DESC",
            new { ruleId }, cancellationToken: ct))).ToList();
    }

    public async Task<RuleVersionRecord?> GetVersionAsync(Guid ruleId, int versionNo, CancellationToken ct)
    {
        await using var conn = Open();
        return await conn.QuerySingleOrDefaultAsync<RuleVersionRecord>(new CommandDefinition(
            "SELECT RuleId, VersionNo, Name, DefinitionJson, CreatedBy, CreatedAt FROM dq.RuleVersion WHERE RuleId = @ruleId AND VersionNo = @versionNo",
            new { ruleId, versionNo }, cancellationToken: ct));
    }
}

public sealed class SqlRunRepository(IOptions<DatabaseOptions> options) : SqlRepositoryBase(options), IRunRepository
{
    private const string SelectRun = @"
        SELECT x.Id, x.RuleId, x.RuleVersionNo, x.Status, x.QueuedAt, x.StartedAt, x.FinishedAt, x.DurationMs, x.ViolationCount, x.StoredCount,
               x.IsTruncated, x.SqlHash, x.ErrorCode, x.ErrorMessage, x.TriggeredBy, r.Name AS RuleName
        FROM dq.RuleRun x JOIN dq.[Rule] r ON r.Id = x.RuleId";

    public async Task InsertAsync(RunRecord run, CancellationToken ct)
    {
        await using var conn = Open();
        await conn.ExecuteAsync(new CommandDefinition(@"
            INSERT INTO dq.RuleRun (Id, RuleId, RuleVersionNo, Status, QueuedAt, IsTruncated, TriggeredBy)
            VALUES (@Id, @RuleId, @RuleVersionNo, @Status, @QueuedAt, 0, @TriggeredBy)", run, cancellationToken: ct));
    }

    public async Task<RunRecord?> GetAsync(Guid id, CancellationToken ct)
    {
        await using var conn = Open();
        return await conn.QuerySingleOrDefaultAsync<RunRecord>(new CommandDefinition($"{SelectRun} WHERE x.Id = @id", new { id }, cancellationToken: ct));
    }

    public async Task<bool> HasActiveRunAsync(Guid ruleId, CancellationToken ct)
    {
        await using var conn = Open();
        return await conn.ExecuteScalarAsync<int>(new CommandDefinition(
            "SELECT COUNT(*) FROM dq.RuleRun WHERE RuleId = @ruleId AND Status IN (N'Queued', N'Running')", new { ruleId }, cancellationToken: ct)) > 0;
    }

    public async Task<IReadOnlyList<RunRecord>> ListForRuleAsync(Guid ruleId, int take, CancellationToken ct)
    {
        await using var conn = Open();
        return (await conn.QueryAsync<RunRecord>(new CommandDefinition(
            $"SELECT TOP (@take) * FROM ({SelectRun} WHERE x.RuleId = @ruleId) q ORDER BY q.QueuedAt DESC", new { ruleId, take }, cancellationToken: ct))).ToList();
    }

    public async Task MarkRunningAsync(Guid id, DateTime at, CancellationToken ct)
    {
        await using var conn = Open();
        await conn.ExecuteAsync(new CommandDefinition(
            "UPDATE dq.RuleRun SET Status = N'Running', StartedAt = @at WHERE Id = @id AND Status = N'Queued'", new { id, at }, cancellationToken: ct));
    }

    public async Task CompleteAsync(RunRecord run, CancellationToken ct)
    {
        await using var conn = Open();
        await conn.ExecuteAsync(new CommandDefinition(@"
            UPDATE dq.RuleRun SET Status = @Status, FinishedAt = @FinishedAt, DurationMs = @DurationMs, ViolationCount = @ViolationCount,
                   StoredCount = @StoredCount, IsTruncated = @IsTruncated, SqlHash = @SqlHash, ErrorCode = @ErrorCode, ErrorMessage = @ErrorMessage
            WHERE Id = @Id", run, cancellationToken: ct));
    }

    public async Task SaveViolationsAsync(Guid runId, IReadOnlyList<ViolationRecord> violations, CancellationToken ct)
    {
        if (violations.Count == 0) return;
        var table = new DataTable();
        table.Columns.Add("RunId", typeof(Guid));
        table.Columns.Add("Seq", typeof(int));
        table.Columns.Add("RecordKey", typeof(string));
        table.Columns.Add("DisplayLabel", typeof(string));
        table.Columns.Add("ReasonsJson", typeof(string));
        table.Columns.Add("FailedConditionIds", typeof(string));
        table.Columns.Add("ValuesJson", typeof(string));
        table.Columns.Add("SearchText", typeof(string));
        foreach (var v in violations)
            table.Rows.Add(runId, v.Seq, v.RecordKey, v.DisplayLabel, v.ReasonsJson, v.FailedConditionIds, v.ValuesJson, v.SearchText);

        await using var conn = Open();
        await conn.OpenAsync(ct);
        using var bulk = new SqlBulkCopy(conn) { DestinationTableName = "dq.RuleRunViolation", BatchSize = 2000 };
        foreach (DataColumn c in table.Columns) bulk.ColumnMappings.Add(c.ColumnName, c.ColumnName);
        await bulk.WriteToServerAsync(table, ct);
    }

    public async Task<PagedResultRecord<ViolationRecord>> ListViolationsAsync(Guid runId, ViolationQuery q, CancellationToken ct)
    {
        var where = "RunId = @runId";
        var p = new DynamicParameters(new { runId, skip = (q.Page - 1) * q.PageSize, take = q.PageSize });
        if (!string.IsNullOrWhiteSpace(q.Search)) { where += " AND SearchText LIKE @search"; p.Add("search", LikeContains(q.Search.Trim())); }
        if (!string.IsNullOrWhiteSpace(q.ConditionId)) { where += " AND FailedConditionIds LIKE @cond"; p.Add("cond", LikeContains("," + q.ConditionId + ",")); }

        await using var conn = Open();
        var total = await conn.ExecuteScalarAsync<long>(new CommandDefinition($"SELECT COUNT_BIG(*) FROM dq.RuleRunViolation WHERE {where}", p, cancellationToken: ct));
        var items = await conn.QueryAsync<ViolationRecord>(new CommandDefinition(
            $"SELECT Seq, RecordKey, DisplayLabel, ReasonsJson, FailedConditionIds, ValuesJson, SearchText FROM dq.RuleRunViolation WHERE {where} ORDER BY Seq OFFSET @skip ROWS FETCH NEXT @take ROWS ONLY",
            p, cancellationToken: ct));
        return new PagedResultRecord<ViolationRecord>(items.ToList(), total);
    }

    public async Task<int> FailInterruptedRunsAsync(DateTime at, CancellationToken ct)
    {
        await using var conn = Open();
        return await conn.ExecuteAsync(new CommandDefinition(@"
            UPDATE dq.RuleRun SET Status = N'Failed', FinishedAt = @at, ErrorCode = N'INTERRUPTED', ErrorMessage = N'ההרצה הופסקה עקב הפעלה מחדש של השרת.'
            WHERE Status IN (N'Queued', N'Running')", new { at }, cancellationToken: ct));
    }
}

public sealed class SqlSuggestionRepository(IOptions<DatabaseOptions> options) : SqlRepositoryBase(options), ISuggestionRepository
{
    private const string Columns = "Id, BatchId, Provider, Title, ExplanationHe, Evidence, Severity, DefinitionJson, Status, ValidationErrors, CreatedAt, ReviewedBy, ReviewedAt, AcceptedRuleId";

    public async Task InsertManyAsync(IReadOnlyList<SuggestionRecord> items, CancellationToken ct)
    {
        if (items.Count == 0) return;
        await using var conn = Open();
        await conn.ExecuteAsync(new CommandDefinition(
            $"INSERT INTO dq.AiSuggestion ({Columns}) VALUES (@Id, @BatchId, @Provider, @Title, @ExplanationHe, @Evidence, @Severity, @DefinitionJson, @Status, @ValidationErrors, @CreatedAt, @ReviewedBy, @ReviewedAt, @AcceptedRuleId)",
            items, cancellationToken: ct));
    }

    public async Task<IReadOnlyList<SuggestionRecord>> ListAsync(Guid? batchId, string? status, CancellationToken ct)
    {
        await using var conn = Open();
        return (await conn.QueryAsync<SuggestionRecord>(new CommandDefinition(
            $"SELECT TOP (200) {Columns} FROM dq.AiSuggestion WHERE (@batchId IS NULL OR BatchId = @batchId) AND (@status IS NULL OR Status = @status) ORDER BY CreatedAt DESC, Title",
            new { batchId, status }, cancellationToken: ct))).ToList();
    }

    public async Task<SuggestionRecord?> GetAsync(Guid id, CancellationToken ct)
    {
        await using var conn = Open();
        return await conn.QuerySingleOrDefaultAsync<SuggestionRecord>(new CommandDefinition(
            $"SELECT {Columns} FROM dq.AiSuggestion WHERE Id = @id", new { id }, cancellationToken: ct));
    }

    public async Task UpdateReviewAsync(SuggestionRecord s, CancellationToken ct)
    {
        await using var conn = Open();
        await conn.ExecuteAsync(new CommandDefinition(
            "UPDATE dq.AiSuggestion SET Status = @Status, ReviewedBy = @ReviewedBy, ReviewedAt = @ReviewedAt, AcceptedRuleId = @AcceptedRuleId WHERE Id = @Id",
            s, cancellationToken: ct));
    }
}
