using System.Data;
using System.Security.Cryptography;
using System.Text;
using DataControls.Application.Abstractions;
using DataControls.Domain.Rules.Binding;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Options;

namespace DataControls.Infrastructure.SqlServer;

public sealed class DatabaseOptions
{
    public string ConnectionString { get; set; } = "";
    /// <summary>Database user (WITHOUT LOGIN) the control queries run as. SELECT on schema biz only.</summary>
    public string RuleReaderUser { get; set; } = "dc_rule_reader";
    public int CommandTimeoutSeconds { get; set; } = 30;
    public int MaxStoredViolations { get; set; } = 10_000;
}

/// <summary>
/// Executes compiled control queries with least privilege: the batch switches to the read-only database user
/// with EXECUTE AS USER, so the database itself rejects any write or any read outside schema biz.
/// Pooling is disabled for this connection so an impersonated session is never reused.
/// </summary>
public sealed class SqlServerRuleQueryExecutor(ICatalogProvider catalog, IOptions<DatabaseOptions> options, IClock clock) : IRuleQueryExecutor
{
    private readonly DatabaseOptions _opt = options.Value;

    public CompiledSqlView Explain(BoundRule rule, int maxRows)
    {
        var q = new SqlServerRuleCompiler(catalog.Current).Compile(rule, maxRows, clock.UtcNow.ToLocalTime());
        return new CompiledSqlView(q.CountSql + "\n\n" + q.RowsSql,
            q.Parameters.Select(p => $"{p.Name} {p.Type}{(p.Size is null ? "" : $"({p.Size})")} = {p.Value}").ToList());
    }

    public async Task<RuleExecutionResult> ExecuteAsync(BoundRule rule, int maxRows, CancellationToken ct)
    {
        var q = new SqlServerRuleCompiler(catalog.Current).Compile(rule, maxRows, clock.UtcNow.ToLocalTime());

        var csb = new SqlConnectionStringBuilder(_opt.ConnectionString) { Pooling = false, ApplicationName = "DataControls.RuleExecutor" };
        await using var conn = new SqlConnection(csb.ConnectionString);
        await conn.OpenAsync(ct);

        var sql = $"EXECUTE AS USER = @__user;\n{q.CountSql}\n{q.RowsSql}\nREVERT;";
        await using var cmd = new SqlCommand(sql, conn) { CommandTimeout = _opt.CommandTimeoutSeconds };
        cmd.Parameters.Add(new SqlParameter("@__user", SqlDbType.NVarChar, 128) { Value = _opt.RuleReaderUser });
        foreach (var p in q.Parameters)
        {
            var sp = new SqlParameter(p.Name, p.Type) { Value = p.Value };
            if (p.Size is not null) sp.Size = p.Size.Value;
            if (p.Precision is not null) sp.Precision = p.Precision.Value;
            if (p.Scale is not null) sp.Scale = p.Scale.Value;
            cmd.Parameters.Add(sp);
        }

        try
        {
            await using var reader = await cmd.ExecuteReaderAsync(ct);
            long total = 0;
            if (await reader.ReadAsync(ct)) total = reader.GetInt64(0);
            await reader.NextResultAsync(ct);

            var rows = new List<ExecutedRow>();
            while (await reader.ReadAsync(ct))
            {
                var flags = new Dictionary<string, bool>(StringComparer.Ordinal);
                foreach (var f in q.Flags) flags[f.NodeId] = Convert.ToInt32(reader[f.Alias]) == 1;

                var values = new Dictionary<string, object?>(StringComparer.Ordinal);
                foreach (var v in q.Values)
                {
                    var raw = reader[v.Alias];
                    values[v.PathKey] = raw is DBNull ? null : raw;
                }

                var label = reader["__label"];
                rows.Add(new ExecutedRow
                {
                    Key = Convert.ToString(reader["__key"], System.Globalization.CultureInfo.InvariantCulture) ?? "",
                    Label = label is DBNull ? null : label,
                    Flags = flags,
                    Values = values,
                });
            }

            return new RuleExecutionResult { TotalCount = total, Rows = rows, SqlHash = Hash(q.RowsSql) };
        }
        catch (SqlException ex) when (ex.Number == -2)
        {
            throw new QueryTimeoutException();
        }
    }

    private static string Hash(string sql) =>
        Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(sql)))[..16];
}
