using System.Text.Json;
using DataControls.Domain.Catalog;
using DataControls.Domain.Rules.Ast;
using DataControls.Domain.Rules.Binding;
using DataControls.Domain.Rules.Explain;
using DataControls.Infrastructure.SqlServer;

namespace DataControls.Tests;

internal static class TestCatalog
{
    public static BusinessCatalog Create()
    {
        FieldDef F(string key, string col, DataType t, bool nullable = false, int? max = null, IReadOnlyList<EnumValueDef>? enums = null) =>
            new() { Key = key, DisplayName = key, ColumnName = col, DataType = t, IsNullable = nullable, MaxLength = max, EnumValues = enums ?? [] };

        var employee = new EntityDef
        {
            Key = "employee", DisplayName = "עובד", DisplayNamePlural = "עובדים", SchemaName = "biz", TableName = "Employees",
            PrimaryKeyColumn = "Id", DisplayFieldKey = "lastName",
            Fields = new Dictionary<string, FieldDef>
            {
                ["lastName"] = F("lastName", "LastName", DataType.String, max: 50),
                ["birthDate"] = F("birthDate", "BirthDate", DataType.Date, nullable: true),
                ["age"] = new() { Key = "age", DisplayName = "age", DataType = DataType.Integer, IsNullable = true, ComputedFunction = "ageYears", ComputedArgFieldKeys = ["birthDate"] },
                ["hireDate"] = F("hireDate", "HireDate", DataType.Date),
                ["terminationDate"] = F("terminationDate", "TerminationDate", DataType.Date, nullable: true),
                ["salary"] = F("salary", "Salary", DataType.Decimal),
                ["email"] = F("email", "Email", DataType.String, nullable: true, max: 200),
                ["status"] = F("status", "Status", DataType.Enum, max: 1, enums: [new("A", "פעיל"), new("T", "סיים")]),
            },
            Relationships = new Dictionary<string, RelationshipDef>
            {
                ["department"] = new() { Key = "department", FromEntityKey = "employee", ToEntityKey = "department", Cardinality = Cardinality.ManyToOne, FromColumn = "DepartmentId", ToColumn = "Id", DisplayName = "המחלקה" },
                ["projectAssignments"] = new() { Key = "projectAssignments", FromEntityKey = "employee", ToEntityKey = "projectAssignment", Cardinality = Cardinality.OneToMany, FromColumn = "Id", ToColumn = "EmployeeId", DisplayName = "שיוכים" },
            },
        };
        var department = new EntityDef
        {
            Key = "department", DisplayName = "מחלקה", DisplayNamePlural = "מחלקות", SchemaName = "biz", TableName = "Departments",
            PrimaryKeyColumn = "Id", DisplayFieldKey = "name",
            Fields = new Dictionary<string, FieldDef>
            {
                ["name"] = F("name", "Name", DataType.String, max: 100),
                ["isActive"] = F("isActive", "IsActive", DataType.Boolean),
            },
            Relationships = new Dictionary<string, RelationshipDef>(),
        };
        var assignment = new EntityDef
        {
            Key = "projectAssignment", DisplayName = "שיוך", DisplayNamePlural = "שיוכים", SchemaName = "biz", TableName = "ProjectAssignments",
            PrimaryKeyColumn = "Id", DisplayFieldKey = "startDate",
            Fields = new Dictionary<string, FieldDef>
            {
                ["startDate"] = F("startDate", "StartDate", DataType.Date),
                ["endDate"] = F("endDate", "EndDate", DataType.Date, nullable: true),
            },
            Relationships = new Dictionary<string, RelationshipDef>(),
        };
        return new BusinessCatalog([employee, department, assignment]);
    }
}

public class RuleEngineTests
{
    private static readonly BusinessCatalog Catalog = TestCatalog.Create();

    private static BindResult Bind(string json) => new RuleBinder(Catalog).Bind(RuleJson.Parse(json));

    private static CompiledRuleQuery Compile(string json)
    {
        var result = Bind(json);
        Assert.True(result.IsValid, string.Join("; ", result.Errors.Select(e => e.Code)));
        return new SqlServerRuleCompiler(Catalog).Compile(result.Rule!, 100, new DateTime(2026, 11, 14));
    }

    private static string Rule(string condition) =>
        $$"""{"schemaVersion":1,"rootEntity":"employee","condition":{{condition}}}""";

    [Fact]
    public void Parses_discriminator_in_any_position_and_rejects_unknown_properties()
    {
        var ok = RuleJson.Parse("""{"rootEntity":"employee","condition":{"id":"c1","left":{"path":["salary"],"kind":"field"},"operator":"gt","right":{"value":1,"kind":"value"},"type":"comparison"}}""");
        Assert.IsType<ComparisonNode>(ok.Condition);

        Assert.ThrowsAny<JsonException>(() => RuleJson.Parse(
            """{"rootEntity":"employee","sql":"DROP TABLE x","condition":{"type":"group","id":"g","children":[]}}"""));
    }

    [Fact]
    public void Unknown_field_is_rejected_before_any_sql_is_built()
    {
        var r = Bind(Rule("""{"type":"comparison","id":"c1","left":{"kind":"field","path":["salary]; DROP TABLE biz.Employees;--"]},"operator":"gt","right":{"kind":"value","value":1}}"""));
        Assert.False(r.IsValid);
        Assert.Contains(r.Errors, e => e.Code == "UNKNOWN_FIELD" && e.NodeId == "c1");
    }

    [Theory]
    [InlineData("""{"type":"comparison","id":"c1","left":{"kind":"field","path":["hireDate"]},"operator":"contains","right":{"kind":"value","value":"x"}}""", "OPERATOR_NOT_ALLOWED")]
    [InlineData("""{"type":"comparison","id":"c1","left":{"kind":"field","path":["salary"]},"operator":"gt","right":{"kind":"value","value":"abc"}}""", "INVALID_VALUE")]
    [InlineData("""{"type":"comparison","id":"c1","left":{"kind":"field","path":["status"]},"operator":"eq","right":{"kind":"value","value":"X"}}""", "INVALID_ENUM_VALUE")]
    [InlineData("""{"type":"comparison","id":"c1","left":{"kind":"field","path":["salary"]},"operator":"lt","right":{"kind":"field","path":["hireDate"]}}""", "TYPE_MISMATCH")]
    [InlineData("""{"type":"comparison","id":"c1","left":{"kind":"field","scope":"root","path":["salary"]},"operator":"isEmpty"}""", "INVALID_SCOPE")]
    [InlineData("""{"type":"comparison","id":"c1","left":{"kind":"field","path":["projectAssignments","startDate"]},"operator":"isEmpty"}""", "COLLECTION_IN_PATH")]
    [InlineData("""{"type":"group","id":"g1","logic":"and","children":[]}""", "EMPTY_GROUP")]
    public void Invalid_definitions_report_a_stable_code(string condition, string code)
    {
        var r = Bind(Rule(condition));
        Assert.False(r.IsValid);
        Assert.Contains(r.Errors, e => e.Code == code);
    }

    [Fact]
    public void Depth_limit_protects_against_huge_rules()
    {
        var json = """{"type":"comparison","id":"leaf","left":{"kind":"field","path":["salary"]},"operator":"isEmpty"}""";
        for (var i = 0; i < 10; i++) json = $$"""{"type":"group","id":"g{{i}}","logic":"and","children":[{{json}}]}""";
        var r = Bind(Rule(json));
        Assert.Contains(r.Errors, e => e.Code == "RULE_LIMITS_EXCEEDED");
    }

    [Fact]
    public void Nullable_operands_get_is_not_null_guards_so_negation_is_safe()
    {
        var q = Compile(Rule("""{"type":"group","id":"g1","logic":"and","negate":true,"children":[{"type":"comparison","id":"c1","left":{"kind":"field","path":["terminationDate"]},"operator":"lt","right":{"kind":"field","path":["hireDate"]}}]}"""));
        Assert.Contains("NOT ((t0.[TerminationDate] IS NOT NULL AND t0.[TerminationDate] < t0.[HireDate]))", q.RowsSql);
    }

    [Fact]
    public void Many_to_one_uses_one_left_join_and_fields_from_it_are_nullable()
    {
        var q = Compile(Rule("""{"type":"group","id":"g1","logic":"or","children":[ {"type":"comparison","id":"c1","left":{"kind":"field","path":["department","isActive"]},"operator":"eq","right":{"kind":"value","value":false}}, {"type":"comparison","id":"c2","left":{"kind":"field","path":["department","name"]},"operator":"startsWith","right":{"kind":"value","value":"50%_x"}}]}"""));
        Assert.Equal(1, CountOf(q.CountSql, "LEFT JOIN [biz].[Departments]"));
        Assert.Contains("t1.[IsActive] IS NOT NULL", q.CountSql);
        var like = q.Parameters.Single(p => p.Value is string s && s.EndsWith('%'));
        Assert.Equal("50\\%\\_x%", like.Value);
    }

    [Fact]
    public void One_to_many_compiles_to_exists_never_to_a_join()
    {
        var q = Compile(Rule("""{"type":"collection","id":"q1","relation":"projectAssignments","quantifier":"any","condition": {"type":"comparison","id":"c1","left":{"kind":"field","path":["startDate"]},"operator":"lt","right":{"kind":"field","scope":"root","path":["hireDate"]}}}"""));
        Assert.Contains("EXISTS (SELECT 1 FROM [biz].[ProjectAssignments] AS t1 WHERE t1.[EmployeeId] = t0.[Id] AND (t1.[StartDate] < t0.[HireDate]))", q.CountSql);
        Assert.DoesNotContain("JOIN [biz].[ProjectAssignments]", q.CountSql);
    }

    [Fact]
    public void Quantifier_none_without_condition_is_not_exists()
    {
        var q = Compile(Rule("""{"type":"collection","id":"q1","relation":"projectAssignments","quantifier":"none"}"""));
        Assert.Contains("NOT EXISTS (SELECT 1 FROM [biz].[ProjectAssignments] AS t1 WHERE t1.[EmployeeId] = t0.[Id])", q.CountSql);
    }

    [Fact]
    public void Literals_are_parameters_and_node_ids_never_reach_the_sql()
    {
        var q = Compile(Rule("""{"type":"comparison","id":"x]; DROP TABLE t;--","left":{"kind":"field","path":["lastName"]},"operator":"eq","right":{"kind":"value","value":"'; DELETE FROM biz.Employees;--"}}"""));
        Assert.DoesNotContain("DROP", q.RowsSql);
        Assert.DoesNotContain("DELETE", q.RowsSql);
        Assert.Contains(q.Parameters, p => (p.Value as string) == "'; DELETE FROM biz.Employees;--");
    }

    [Fact]
    public void Computed_age_uses_the_run_date_parameter()
    {
        var q = Compile(Rule("""{"type":"comparison","id":"c1","left":{"kind":"field","path":["age"]},"operator":"lt","right":{"kind":"value","value":18}}"""));
        Assert.Contains("DATEDIFF(YEAR, t0.[BirthDate], @__today)", q.RowsSql);
        Assert.Contains("t0.[BirthDate] IS NOT NULL", q.RowsSql);
    }

    [Fact]
    public void Explanation_lists_only_the_or_branches_that_matched()
    {
        var bound = Bind(Rule("""{"type":"group","id":"g1","logic":"or","children":[ {"type":"comparison","id":"c1","left":{"kind":"field","path":["salary"]},"operator":"gt","right":{"kind":"value","value":15000}}, {"type":"comparison","id":"c2","left":{"kind":"field","path":["email"]},"operator":"isEmpty"}]}""")).Rule!;
        var reasons = ExplanationBuilder.Explain(bound,
            new Dictionary<string, bool> { ["c1"] = false, ["c2"] = true },
            new Dictionary<string, object?> { ["salary"] = 9000m, ["email"] = null });
        var reason = Assert.Single(reasons);
        Assert.Equal("c2", reason.ConditionId);
    }

    [Fact]
    public void Involved_fields_are_business_names_including_related_records()
    {
        var bound = Bind(Rule("""{"type":"group","id":"g1","logic":"or","children":[{"type":"comparison","id":"c0","left":{"kind":"field","path":["department","isActive"]},"operator":"eq","right":{"kind":"value","value":false}},{"type":"collection","id":"q1","relation":"projectAssignments","quantifier":"any","condition":{"type":"comparison","id":"c1","left":{"kind":"field","path":["startDate"]},"operator":"lt","right":{"kind":"field","scope":"root","path":["hireDate"]}}}]}""")).Rule!;
        Assert.Equal(new[] { "המחלקה › isActive", "שיוכים › startDate", "hireDate" }, RuleDescriber.InvolvedFields(bound));
    }

    private static int CountOf(string text, string part) => (text.Length - text.Replace(part, "").Length) / part.Length;
}
