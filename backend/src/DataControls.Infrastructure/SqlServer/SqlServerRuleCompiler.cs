using System.Data;
using System.Text;
using DataControls.Domain.Catalog;
using DataControls.Domain.Rules.Ast;
using DataControls.Domain.Rules.Binding;

namespace DataControls.Infrastructure.SqlServer;

public sealed record SqlParam(string Name, SqlDbType Type, object Value, int? Size = null, byte? Precision = null, byte? Scale = null);

public sealed record FlagColumn(string Alias, string NodeId);

public sealed record ValueColumn(string Alias, string PathKey);

public sealed class CompiledRuleQuery
{
    public required string CountSql { get; init; }
    public required string RowsSql { get; init; }
    public required IReadOnlyList<SqlParam> Parameters { get; init; }
    public required IReadOnlyList<FlagColumn> Flags { get; init; }
    public required IReadOnlyList<ValueColumn> Values { get; init; }
}

/// <summary>
/// Compiles a BOUND rule (catalog objects + typed literals) into parameterized T-SQL.
///
/// Security model - the SQL text is built ONLY from:
///   * fixed keywords and operators chosen by a closed switch (never from input),
///   * schema/table/column names taken from the verified catalog, bracket-quoted,
///   * aliases generated here (t0, t1, f0, v0) - node ids from the request never reach the SQL,
///   * parameter placeholders; every literal is a typed SqlParameter.
///
/// Semantics:
///   * Every leaf predicate is two-valued: nullable operands get "IS NOT NULL" guards, so a NULL never yields
///     UNKNOWN. Therefore NOT(...), quantifier "none" and "all" behave correctly (no rows silently lost).
///   * Many-to-one paths -> LEFT JOIN (one alias per distinct path, shared). One-to-many -> correlated
///     EXISTS / NOT EXISTS, never a JOIN, so a parent with many children appears exactly once.
/// </summary>
public sealed class SqlServerRuleCompiler
{
    private sealed class ScopeSql(string alias)
    {
        public string Alias { get; } = alias;
        public Dictionary<string, string> JoinAliases { get; } = new(StringComparer.Ordinal);
        public List<(string Alias, string ParentAlias, RelationshipDef Rel, EntityDef Target)> Joins { get; } = [];
    }

    private readonly BusinessCatalog _catalog;
    private readonly Dictionary<Scope, ScopeSql> _scopes = new(ReferenceEqualityComparer.Instance);
    private readonly List<SqlParam> _params = [];
    private int _aliasCounter;

    public SqlServerRuleCompiler(BusinessCatalog catalog) => _catalog = catalog;

    public CompiledRuleQuery Compile(BoundRule rule, int maxRows, DateTime today)
    {
        _params.Add(new SqlParam("@__today", SqlDbType.Date, today.Date));
        _params.Add(new SqlParam("@__cap", SqlDbType.Int, maxRows));

        var root = For(rule.RootScope);
        var where = Predicate(rule.Condition);

        // Explanation flags: one per comparison/collection in the root scope (evaluated only for returned rows).
        var flags = new List<FlagColumn>();
        var flagSql = new StringBuilder();
        foreach (var leaf in RootLeaves(rule.Condition))
        {
            var alias = $"f{flags.Count}";
            flags.Add(new FlagColumn(alias, leaf.Id));
            flagSql.Append($",\n       CASE WHEN {Predicate(leaf)} THEN 1 ELSE 0 END AS [{alias}]");
        }

        // Values: display fields + every field used by a root-scope comparison (shown in the explanation).
        var valueFields = new Dictionary<string, BoundField>(StringComparer.Ordinal);
        foreach (var f in rule.DisplayFields) valueFields.TryAdd(f.PathKey, f);
        foreach (var c in RootLeaves(rule.Condition).OfType<BoundComparison>())
        {
            valueFields.TryAdd(c.Left.PathKey, c.Left);
            if (c.Right is BoundField rf && ReferenceEquals(rf.Scope, rule.RootScope)) valueFields.TryAdd(rf.PathKey, rf);
        }
        var values = new List<ValueColumn>();
        var valueSql = new StringBuilder();
        foreach (var (key, f) in valueFields)
        {
            var alias = $"v{values.Count}";
            values.Add(new ValueColumn(alias, key));
            valueSql.Append($",\n       {FieldExpr(f)} AS [{alias}]");
        }

        var keyExpr = $"{root.Alias}.{Q(rule.Root.PrimaryKeyColumn)}";
        var labelExpr = FieldExpr(RootField(rule.RootScope, rule.Root.DisplayFieldKey));
        var from = From(rule.Root, root);

        var rows =
            $"SELECT TOP (@__cap)\n       {keyExpr} AS [__key],\n       {labelExpr} AS [__label]{flagSql}{valueSql}\n" +
            $"FROM {from}\nWHERE {where}\nORDER BY {keyExpr};";
        var count = $"SELECT COUNT_BIG(*)\nFROM {from}\nWHERE {where};";

        return new CompiledRuleQuery { CountSql = count, RowsSql = rows, Parameters = _params, Flags = flags, Values = values };
    }

    // ---------- scopes, joins, identifiers ----------

    private ScopeSql For(Scope scope)
    {
        if (!_scopes.TryGetValue(scope, out var s))
        {
            s = new ScopeSql($"t{_aliasCounter++}");
            _scopes[scope] = s;
        }
        return s;
    }

    private string AliasFor(BoundField f)
    {
        var scope = For(f.Scope);
        var alias = scope.Alias;
        var path = "";
        foreach (var rel in f.Joins)
        {
            path = path.Length == 0 ? rel.Key : $"{path}.{rel.Key}";
            if (!scope.JoinAliases.TryGetValue(path, out var joinAlias))
            {
                joinAlias = $"t{_aliasCounter++}";
                scope.JoinAliases[path] = joinAlias;
                scope.Joins.Add((joinAlias, alias, rel, _catalog.Entities[rel.ToEntityKey]));
            }
            alias = joinAlias;
        }
        return alias;
    }

    private static string From(EntityDef entity, ScopeSql scope)
    {
        var sb = new StringBuilder($"{Table(entity)} AS {scope.Alias}");
        foreach (var (alias, parent, rel, target) in scope.Joins)
            sb.Append($"\nLEFT JOIN {Table(target)} AS {alias} ON {alias}.{Q(rel.ToColumn)} = {parent}.{Q(rel.FromColumn)}");
        return sb.ToString();
    }

    public static string Q(string identifier) => "[" + identifier.Replace("]", "]]") + "]";

    private static string Table(EntityDef e) => $"{Q(e.SchemaName)}.{Q(e.TableName)}";

    private static BoundField RootField(Scope scope, string key)
    {
        var field = scope.Entity.Fields[key];
        var args = field.ComputedArgFieldKeys.Select(k => new BoundField(scope, [], scope.Entity, scope.Entity.Fields[k])).ToList();
        return new BoundField(scope, [], scope.Entity, field) { ComputedArgs = args };
    }

    private string FieldExpr(BoundField f)
    {
        if (!f.Field.IsComputed)
            return $"{AliasFor(f)}.{Q(f.Field.ColumnName!)}";

        var args = f.ComputedArgs.Select(FieldExpr).ToArray();
        return f.Field.ComputedFunction switch
        {
            "ageYears" => $"(DATEDIFF(YEAR, {args[0]}, @__today) - CASE WHEN DATEADD(YEAR, DATEDIFF(YEAR, {args[0]}, @__today), {args[0]}) > @__today THEN 1 ELSE 0 END)",
            "fullName" => $"CONCAT({args[0]}, N' ', {args[1]})",
            _ => throw new NotSupportedException($"Function '{f.Field.ComputedFunction}' is not in the function catalog."),
        };
    }

    // ---------- predicates ----------

    private static IEnumerable<BoundNode> RootLeaves(BoundNode node) => node switch
    {
        BoundGroup g => g.Children.SelectMany(RootLeaves),
        _ => new[] { node },
    };

    private readonly Dictionary<BoundNode, string> _predicates = new(ReferenceEqualityComparer.Instance);

    /// <summary>Each node is compiled once (WHERE and the explanation flags reuse the same text and parameters).</summary>
    private string Predicate(BoundNode node)
    {
        if (_predicates.TryGetValue(node, out var cached)) return cached;
        var sql = node switch
        {
            BoundGroup g => GroupPredicate(g),
            BoundComparison c => ComparisonPredicate(c),
            BoundCollection c => CollectionPredicate(c),
            _ => throw new NotSupportedException(node.GetType().Name),
        };
        _predicates[node] = sql;
        return sql;
    }

    private string GroupPredicate(BoundGroup g)
    {
        var joiner = g.Logic == LogicOp.And ? " AND " : " OR ";
        var inner = "(" + string.Join(joiner, g.Children.Select(Predicate)) + ")";
        return g.Negate ? $"NOT {inner}" : inner;
    }

    private string CollectionPredicate(BoundCollection c)
    {
        var parent = For(c.ParentScope);
        var child = For(c.ChildScope);
        var correlation = $"{child.Alias}.{Q(c.Relation.ToColumn)} = {parent.Alias}.{Q(c.Relation.FromColumn)}";

        var inner = c.Condition is null ? null : Predicate(c.Condition); // compile first: collects the child joins
        var where = inner is null
            ? correlation
            : c.Quantifier == Quantifier.All ? $"{correlation} AND NOT ({inner})" : $"{correlation} AND ({inner})";

        var exists = $"EXISTS (SELECT 1 FROM {From(c.ChildScope.Entity, child)} WHERE {where})";
        return c.Quantifier == Quantifier.Any ? exists : $"NOT {exists}";
    }

    private string ComparisonPredicate(BoundComparison c)
    {
        var l = FieldExpr(c.Left);
        var isString = c.Left.DataType is DataType.String or DataType.Enum;

        switch (c.Operator)
        {
            case Operator.IsEmpty:
                return isString ? $"({l} IS NULL OR LTRIM(RTRIM({l})) = N'')" : $"{l} IS NULL";
            case Operator.IsNotEmpty:
                return isString ? $"({l} IS NOT NULL AND LTRIM(RTRIM({l})) <> N'')" : $"{l} IS NOT NULL";
        }

        var guards = new List<string>();
        AddNullGuards(c.Left, l, guards);

        string core;
        if (c.Right is BoundField rf)
        {
            var r = FieldExpr(rf);
            AddNullGuards(rf, r, guards);
            core = $"{l} {Cmp(c.Operator)} {r}";
        }
        else core = c.Operator switch
        {
            Operator.Between when c.Right is BoundRange r =>
                $"{l} BETWEEN {Param(c.Left.Field, r.From)} AND {Param(c.Left.Field, r.To)}",
            Operator.In when c.Right is BoundList list =>
                $"{l} IN ({string.Join(", ", list.Values.Select(v => Param(c.Left.Field, v)))})",
            Operator.NotIn when c.Right is BoundList list =>
                $"{l} NOT IN ({string.Join(", ", list.Values.Select(v => Param(c.Left.Field, v)))})",
            Operator.Contains or Operator.StartsWith or Operator.EndsWith when c.Right is BoundLiteral lit =>
                $"{l} LIKE {LikeParam(c.Operator, (string)lit.Value)} ESCAPE N'\\'",
            _ when c.Right is BoundLiteral lit =>
                $"{l} {Cmp(c.Operator)} {Param(c.Left.Field, lit.Value)}",
            _ => throw new NotSupportedException($"Unsupported comparison {c.Operator}"),
        };

        return guards.Count == 0 ? core : "(" + string.Join(" AND ", guards.Append(core)) + ")";
    }

    /// <summary>
    /// Makes the predicate two-valued. For computed fields the guard is placed on the nullable arguments
    /// (e.g. BirthDate IS NOT NULL) which keeps the SQL readable and index friendly.
    /// </summary>
    private void AddNullGuards(BoundField f, string expr, List<string> guards)
    {
        if (!f.IsNullable) return;
        if (f.Field.IsComputed && f.ComputedArgs.Count > 0)
        {
            foreach (var arg in f.ComputedArgs.Where(a => a.IsNullable))
                guards.Add($"{FieldExpr(arg)} IS NOT NULL");
            return;
        }
        guards.Add($"{expr} IS NOT NULL");
    }

    private static string Cmp(Operator op) => op switch
    {
        Operator.Eq => "=",
        Operator.Neq => "<>",
        Operator.Gt => ">",
        Operator.Gte => ">=",
        Operator.Lt => "<",
        Operator.Lte => "<=",
        _ => throw new NotSupportedException(op.ToString()),
    };

    private string Param(FieldDef field, object value)
    {
        var name = $"@p{_params.Count - 2}";
        _params.Add(field.DataType switch
        {
            DataType.String or DataType.Enum => new SqlParam(name, SqlDbType.NVarChar, value, Size: field.MaxLength is > 0 and <= 4000 ? field.MaxLength : 4000),
            DataType.Integer => new SqlParam(name, SqlDbType.BigInt, Convert.ToInt64(value)),
            DataType.Decimal => new SqlParam(name, SqlDbType.Decimal, Convert.ToDecimal(value), Precision: 18, Scale: 4),
            DataType.Date => new SqlParam(name, SqlDbType.Date, value),
            DataType.DateTime => new SqlParam(name, SqlDbType.DateTime2, value),
            DataType.Boolean => new SqlParam(name, SqlDbType.Bit, value),
            _ => throw new NotSupportedException(field.DataType.ToString()),
        });
        return name;
    }

    /// <summary>LIKE wildcards in the user's text are escaped, so "50%" matches the literal text "50%".</summary>
    private string LikeParam(Operator op, string text)
    {
        var escaped = text.Replace("\\", "\\\\").Replace("%", "\\%").Replace("_", "\\_").Replace("[", "\\[");
        var pattern = op switch
        {
            Operator.StartsWith => escaped + "%",
            Operator.EndsWith => "%" + escaped,
            _ => "%" + escaped + "%",
        };
        var name = $"@p{_params.Count - 2}";
        _params.Add(new SqlParam(name, SqlDbType.NVarChar, pattern, Size: 4000));
        return name;
    }
}
