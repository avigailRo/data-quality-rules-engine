using DataControls.Domain.Catalog;
using DataControls.Domain.Rules.Ast;

namespace DataControls.Domain.Rules.Binding;

/// <summary>A query scope: the root entity, or the child entity inside a collection condition.</summary>
public sealed class Scope(EntityDef entity, Scope? parent)
{
    public EntityDef Entity { get; } = entity;
    public Scope? Parent { get; } = parent;
    public Scope Root => Parent?.Root ?? this;
}

public abstract class BoundNode(string id)
{
    public string Id { get; } = id;
}

public sealed class BoundGroup(string id, LogicOp logic, bool negate, IReadOnlyList<BoundNode> children) : BoundNode(id)
{
    public LogicOp Logic { get; } = logic;
    public bool Negate { get; } = negate;
    public IReadOnlyList<BoundNode> Children { get; } = children;
}

public sealed class BoundComparison(string id, BoundField left, Operator op, BoundOperand? right) : BoundNode(id)
{
    public BoundField Left { get; } = left;
    public Operator Operator { get; } = op;
    public BoundOperand? Right { get; } = right;
}

public sealed class BoundCollection(string id, Scope parentScope, RelationshipDef relation, Scope childScope, Quantifier quantifier, BoundNode? condition) : BoundNode(id)
{
    public Scope ParentScope { get; } = parentScope;
    public RelationshipDef Relation { get; } = relation;
    public Scope ChildScope { get; } = childScope;
    public Quantifier Quantifier { get; } = quantifier;
    public BoundNode? Condition { get; } = condition;
}

public abstract class BoundOperand { }

/// <summary>A field resolved against the catalog. Joins = chain of many-to-one relationships from the scope entity.</summary>
public sealed class BoundField(Scope scope, IReadOnlyList<RelationshipDef> joins, EntityDef owner, FieldDef field) : BoundOperand
{
    public Scope Scope { get; } = scope;
    public IReadOnlyList<RelationshipDef> Joins { get; } = joins;
    public EntityDef Owner { get; } = owner;
    public FieldDef Field { get; } = field;
    public IReadOnlyList<BoundField> ComputedArgs { get; init; } = [];

    public DataType DataType => Field.DataType;

    /// <summary>A field reached through a LEFT JOIN can be NULL even if its column is NOT NULL.</summary>
    public bool IsNullable => Field.IsNullable || Joins.Count > 0 || ComputedArgs.Any(a => a.IsNullable);

    public string PathKey => string.Join('.', Joins.Select(j => j.Key).Append(Field.Key));

    public string JoinPathKey => string.Join('.', Joins.Select(j => j.Key));

    public string DisplayName => string.Join(" › ", Joins.Select(j => j.DisplayName).Append(Field.DisplayName));
}

public sealed class BoundLiteral(DataType type, object value) : BoundOperand
{
    public DataType Type { get; } = type;
    public object Value { get; } = value;
}

public sealed class BoundList(DataType type, IReadOnlyList<object> values) : BoundOperand
{
    public DataType Type { get; } = type;
    public IReadOnlyList<object> Values { get; } = values;
}

public sealed class BoundRange(DataType type, object from, object to) : BoundOperand
{
    public DataType Type { get; } = type;
    public object From { get; } = from;
    public object To { get; } = to;
}

public sealed class BoundRule(RuleDefinition source, Scope rootScope, BoundNode condition, IReadOnlyList<BoundField> displayFields)
{
    public RuleDefinition Source { get; } = source;
    public Scope RootScope { get; } = rootScope;
    public EntityDef Root => RootScope.Entity;
    public BoundNode Condition { get; } = condition;
    public IReadOnlyList<BoundField> DisplayFields { get; } = displayFields;
}

public sealed record ValidationError(string? NodeId, string Code, string MessageHe);

public sealed class BindResult
{
    public BoundRule? Rule { get; init; }
    public IReadOnlyList<ValidationError> Errors { get; init; } = [];
    public bool IsValid => Rule is not null && Errors.Count == 0;
}
