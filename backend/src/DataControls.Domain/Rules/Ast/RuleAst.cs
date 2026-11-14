using System.Text.Json;
using System.Text.Json.Serialization;

namespace DataControls.Domain.Rules.Ast;

/// <summary>
/// Typed rule definition. A rule describes the VIOLATION condition: records that satisfy it are anomalies.
/// The definition never contains SQL or physical names - only business keys from the catalog and literals.
/// </summary>
public sealed class RuleDefinition
{
    public int SchemaVersion { get; init; } = 1;
    public string RootEntity { get; init; } = "";
    public ConditionNode? Condition { get; init; }
    public OutputSpec? Output { get; init; }
}

public sealed class OutputSpec
{
    /// <summary>Field paths ("salary", "department.name") shown next to every violation.</summary>
    public List<string> DisplayFields { get; init; } = [];
}

[JsonPolymorphic(TypeDiscriminatorPropertyName = "type")]
[JsonDerivedType(typeof(GroupNode), "group")]
[JsonDerivedType(typeof(ComparisonNode), "comparison")]
[JsonDerivedType(typeof(CollectionNode), "collection")]
public abstract class ConditionNode
{
    public string Id { get; init; } = "";
}

public enum LogicOp { And, Or }

public sealed class GroupNode : ConditionNode
{
    public LogicOp Logic { get; init; } = LogicOp.And;
    public bool Negate { get; init; }
    public List<ConditionNode> Children { get; init; } = [];
}

public enum Operator
{
    Eq, Neq, Gt, Gte, Lt, Lte, Between, In, NotIn, Contains, StartsWith, EndsWith, IsEmpty, IsNotEmpty
}

public sealed class ComparisonNode : ConditionNode
{
    public Operand? Left { get; init; }
    public Operator Operator { get; init; }
    public Operand? Right { get; init; }
}

public enum Quantifier { Any, None, All }

/// <summary>Condition over a one-to-many relationship. Compiled to EXISTS / NOT EXISTS (never a JOIN).</summary>
public sealed class CollectionNode : ConditionNode
{
    public string Relation { get; init; } = "";
    public Quantifier Quantifier { get; init; } = Quantifier.Any;
    /// <summary>Optional: without a condition, "any" = has related records, "none" = has no related records.</summary>
    public ConditionNode? Condition { get; init; }
}

[JsonPolymorphic(TypeDiscriminatorPropertyName = "kind")]
[JsonDerivedType(typeof(FieldOperand), "field")]
[JsonDerivedType(typeof(ValueOperand), "value")]
[JsonDerivedType(typeof(ValuesOperand), "values")]
[JsonDerivedType(typeof(RangeOperand), "range")]
public abstract class Operand { }

public sealed class FieldOperand : Operand
{
    /// <summary>Business keys, relative to the current scope: ["salary"] or ["department", "isActive"].</summary>
    public List<string> Path { get; init; } = [];
    /// <summary>null = current scope; "root" = the root record (only inside a collection condition).</summary>
    public string? Scope { get; init; }
}

public sealed class ValueOperand : Operand
{
    public JsonElement Value { get; init; }
}

public sealed class ValuesOperand : Operand
{
    public List<JsonElement> Values { get; init; } = [];
}

public sealed class RangeOperand : Operand
{
    public JsonElement From { get; init; }
    public JsonElement To { get; init; }
}

public static class RuleJson
{
    public static readonly JsonSerializerOptions Options = Create();

    private static JsonSerializerOptions Create()
    {
        var o = new JsonSerializerOptions(JsonSerializerDefaults.Web)
        {
            AllowOutOfOrderMetadataProperties = true,
            UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow,
            MaxDepth = 64,
            DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        };
        o.Converters.Add(new JsonStringEnumConverter(JsonNamingPolicy.CamelCase, allowIntegerValues: false));
        return o;
    }

    public static RuleDefinition Parse(string json) =>
        JsonSerializer.Deserialize<RuleDefinition>(json, Options) ?? throw new JsonException("Empty definition");

    public static string Serialize(RuleDefinition def) => JsonSerializer.Serialize(def, Options);
}
