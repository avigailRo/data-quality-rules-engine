using System.Globalization;
using System.Text.Json;
using DataControls.Domain.Catalog;
using DataControls.Domain.Rules.Ast;

namespace DataControls.Domain.Rules.Binding;

public sealed record RuleLimits(int MaxDepth = 6, int MaxNodes = 60, int MaxCollectionDepth = 2, int MaxListValues = 200, int MaxStringLength = 400, int MaxDisplayFields = 10);

/// <summary>
/// Binds every business key in a rule to the catalog and validates types, operators and limits.
/// After binding there are no free-form strings left: only catalog objects and typed literals.
/// All errors are collected (not fail-fast) so the UI can mark every invalid condition.
/// </summary>
public sealed class RuleBinder(BusinessCatalog catalog, RuleLimits? limits = null)
{
    private readonly RuleLimits _limits = limits ?? new RuleLimits();

    public BindResult Bind(RuleDefinition def)
    {
        var ctx = new Ctx();

        if (def.SchemaVersion != 1)
            ctx.Error(null, "SCHEMA_VERSION", "גרסת מבנה הבקרה אינה נתמכת.");

        var root = catalog.FindEntity(def.RootEntity);
        if (root is null)
        {
            ctx.Error(null, "UNKNOWN_ENTITY", "יש לבחור נושא בקרה קיים.");
            return new BindResult { Errors = ctx.Errors };
        }

        if (def.Condition is null)
        {
            ctx.Error(null, "EMPTY_CONDITION", "יש להגדיר לפחות תנאי אחד.");
            return new BindResult { Errors = ctx.Errors };
        }

        var rootScope = new Scope(root, null);
        var condition = BindNode(def.Condition, rootScope, ctx, depth: 1, collectionDepth: 0);

        var displayFields = new List<BoundField>();
        List<string> requested = def.Output?.DisplayFields is { Count: > 0 } d ? d : new List<string> { root.DisplayFieldKey };
        if (requested.Count > _limits.MaxDisplayFields)
            ctx.Error(null, "TOO_MANY_DISPLAY_FIELDS", $"ניתן להציג עד {_limits.MaxDisplayFields} שדות.");
        foreach (var p in requested.Take(_limits.MaxDisplayFields))
        {
            var f = BindField(new FieldOperand { Path = [.. p.Split('.')] }, rootScope, null, ctx);
            if (f is not null) displayFields.Add(f);
        }

        if (ctx.Errors.Count > 0 || condition is null)
            return new BindResult { Errors = ctx.Errors };

        return new BindResult { Rule = new BoundRule(def, rootScope, condition, displayFields) };
    }

    private sealed class Ctx
    {
        public List<ValidationError> Errors { get; } = [];
        public HashSet<string> Ids { get; } = new(StringComparer.Ordinal);
        public int Nodes;
        public void Error(string? nodeId, string code, string message) => Errors.Add(new ValidationError(nodeId, code, message));
    }

    private BoundNode? BindNode(ConditionNode node, Scope scope, Ctx ctx, int depth, int collectionDepth)
    {
        ctx.Nodes++;
        if (ctx.Nodes > _limits.MaxNodes)
        {
            if (ctx.Nodes == _limits.MaxNodes + 1)
                ctx.Error(node.Id, "RULE_LIMITS_EXCEEDED", $"הבקרה מורכבת מדי (יותר מ־{_limits.MaxNodes} תנאים).");
            return null;
        }
        if (depth > _limits.MaxDepth)
        {
            ctx.Error(node.Id, "RULE_LIMITS_EXCEEDED", $"עומק הקינון המרבי הוא {_limits.MaxDepth}.");
            return null;
        }
        if (string.IsNullOrWhiteSpace(node.Id) || node.Id.Length > 40)
            ctx.Error(node.Id, "INVALID_NODE_ID", "לכל תנאי נדרש מזהה תקין.");
        else if (!ctx.Ids.Add(node.Id))
            ctx.Error(node.Id, "DUPLICATE_NODE_ID", "מזהה תנאי מופיע יותר מפעם אחת.");

        return node switch
        {
            GroupNode g => BindGroup(g, scope, ctx, depth, collectionDepth),
            ComparisonNode c => BindComparison(c, scope, ctx),
            CollectionNode c => BindCollection(c, scope, ctx, depth, collectionDepth),
            _ => null,
        };
    }

    private BoundNode? BindGroup(GroupNode g, Scope scope, Ctx ctx, int depth, int collectionDepth)
    {
        if (g.Children.Count == 0)
        {
            ctx.Error(g.Id, "EMPTY_GROUP", "קבוצת תנאים ריקה – הוסיפו תנאי או מחקו את הקבוצה.");
            return null;
        }
        var children = new List<BoundNode>();
        foreach (var child in g.Children)
        {
            var b = BindNode(child, scope, ctx, depth + 1, collectionDepth);
            if (b is not null) children.Add(b);
        }
        return children.Count == g.Children.Count ? new BoundGroup(g.Id, g.Logic, g.Negate, children) : null;
    }

    private BoundNode? BindCollection(CollectionNode c, Scope scope, Ctx ctx, int depth, int collectionDepth)
    {
        if (!scope.Entity.Relationships.TryGetValue(c.Relation, out var rel))
        {
            ctx.Error(c.Id, "UNKNOWN_RELATION", "הקשר שנבחר אינו קיים בקטלוג.");
            return null;
        }
        if (rel.Cardinality != Cardinality.OneToMany)
        {
            ctx.Error(c.Id, "NOT_A_COLLECTION", $"\"{rel.DisplayName}\" הוא רשומה בודדת ולא רשימה – בחרו את השדה ישירות.");
            return null;
        }
        if (collectionDepth + 1 > _limits.MaxCollectionDepth)
        {
            ctx.Error(c.Id, "RULE_LIMITS_EXCEEDED", "לא ניתן לקנן יותר משתי רמות של רשומות קשורות.");
            return null;
        }
        var child = catalog.FindEntity(rel.ToEntityKey);
        if (child is null)
        {
            ctx.Error(c.Id, "UNKNOWN_ENTITY", "הישות הקשורה אינה קיימת בקטלוג.");
            return null;
        }
        if (c.Quantifier == Quantifier.All && c.Condition is null)
        {
            ctx.Error(c.Id, "MISSING_CONDITION", "עבור \"כל הרשומות\" יש להגדיר תנאי.");
            return null;
        }

        var childScope = new Scope(child, scope);
        BoundNode? inner = null;
        if (c.Condition is not null)
        {
            inner = BindNode(c.Condition, childScope, ctx, depth + 1, collectionDepth + 1);
            if (inner is null) return null;
        }
        return new BoundCollection(c.Id, scope, rel, childScope, c.Quantifier, inner);
    }

    private BoundNode? BindComparison(ComparisonNode c, Scope scope, Ctx ctx)
    {
        if (c.Left is not FieldOperand leftOperand)
        {
            ctx.Error(c.Id, "LEFT_MUST_BE_FIELD", "צד שמאל של תנאי חייב להיות שדה.");
            return null;
        }
        var left = BindField(leftOperand, scope, c.Id, ctx);
        if (left is null) return null;

        var type = left.DataType;
        if (!OperatorCatalog.AllowedFor(type).Contains(c.Operator))
        {
            ctx.Error(c.Id, "OPERATOR_NOT_ALLOWED", $"הפעולה \"{OperatorCatalog.LabelHe(c.Operator, type)}\" אינה מתאימה לשדה \"{left.DisplayName}\".");
            return null;
        }

        BoundOperand? right = null;
        switch (OperatorCatalog.ShapeOf(c.Operator))
        {
            case OperandShape.None:
                if (c.Right is not null)
                {
                    ctx.Error(c.Id, "UNEXPECTED_VALUE", "לפעולה זו אין להזין ערך.");
                    return null;
                }
                break;

            case OperandShape.List:
                if (c.Right is not ValuesOperand vs || vs.Values.Count == 0)
                {
                    ctx.Error(c.Id, "MISSING_VALUE", "יש לבחור לפחות ערך אחד.");
                    return null;
                }
                if (vs.Values.Count > _limits.MaxListValues)
                {
                    ctx.Error(c.Id, "RULE_LIMITS_EXCEEDED", $"ניתן לבחור עד {_limits.MaxListValues} ערכים.");
                    return null;
                }
                var parsed = new List<object>();
                foreach (var v in vs.Values)
                {
                    var p = ParseLiteral(v, left.Field, c.Id, ctx);
                    if (p is null) return null;
                    parsed.Add(p);
                }
                right = new BoundList(type, parsed);
                break;

            case OperandShape.Range:
                if (c.Right is not RangeOperand r)
                {
                    ctx.Error(c.Id, "MISSING_VALUE", "יש להזין ערך התחלה וערך סיום.");
                    return null;
                }
                var from = ParseLiteral(r.From, left.Field, c.Id, ctx);
                var to = ParseLiteral(r.To, left.Field, c.Id, ctx);
                if (from is null || to is null) return null;
                if (Comparer<object>.Default.Compare(from, to) > 0)
                {
                    ctx.Error(c.Id, "INVALID_RANGE", "ערך ההתחלה גדול מערך הסיום.");
                    return null;
                }
                right = new BoundRange(type, from, to);
                break;

            case OperandShape.Single:
                switch (c.Right)
                {
                    case ValueOperand v:
                        var value = ParseLiteral(v.Value, left.Field, c.Id, ctx);
                        if (value is null) return null;
                        right = new BoundLiteral(type, value);
                        break;
                    case FieldOperand f:
                        var rf = BindField(f, scope, c.Id, ctx);
                        if (rf is null) return null;
                        if (!OperatorCatalog.AreCompatible(type, rf.DataType) || !OperatorCatalog.AllowsFieldComparison(c.Operator, type))
                        {
                            ctx.Error(c.Id, "TYPE_MISMATCH", $"לא ניתן להשוות את \"{left.DisplayName}\" ל\"{rf.DisplayName}\".");
                            return null;
                        }
                        right = rf;
                        break;
                    default:
                        ctx.Error(c.Id, "MISSING_VALUE", "יש להזין ערך להשוואה.");
                        return null;
                }
                break;
        }

        return new BoundComparison(c.Id, left, c.Operator, right);
    }

    private BoundField? BindField(FieldOperand f, Scope scope, string? nodeId, Ctx ctx)
    {
        var target = scope;
        if (f.Scope == "root")
        {
            if (scope.Parent is null)
            {
                ctx.Error(nodeId, "INVALID_SCOPE", "הפניה לרשומה הראשית אפשרית רק בתוך תנאי על רשומות קשורות.");
                return null;
            }
            target = scope.Root;
        }
        else if (f.Scope is not null)
        {
            ctx.Error(nodeId, "INVALID_SCOPE", "היקף שדה לא מוכר.");
            return null;
        }

        if (f.Path.Count is 0 or > 4)
        {
            ctx.Error(nodeId, "INVALID_PATH", "יש לבחור שדה.");
            return null;
        }

        var entity = target.Entity;
        var joins = new List<RelationshipDef>();
        for (var i = 0; i < f.Path.Count - 1; i++)
        {
            if (!entity.Relationships.TryGetValue(f.Path[i], out var rel))
            {
                ctx.Error(nodeId, "UNKNOWN_FIELD", "השדה שנבחר אינו קיים בקטלוג.");
                return null;
            }
            if (rel.Cardinality != Cardinality.ManyToOne)
            {
                ctx.Error(nodeId, "COLLECTION_IN_PATH", $"\"{rel.DisplayName}\" היא רשימה – השתמשו בתנאי על רשומות קשורות.");
                return null;
            }
            joins.Add(rel);
            entity = catalog.FindEntity(rel.ToEntityKey)!;
        }

        if (!entity.Fields.TryGetValue(f.Path[^1], out var field))
        {
            ctx.Error(nodeId, "UNKNOWN_FIELD", "השדה שנבחר אינו קיים בקטלוג.");
            return null;
        }

        var args = new List<BoundField>();
        foreach (var argKey in field.ComputedArgFieldKeys)
        {
            if (!entity.Fields.TryGetValue(argKey, out var argField) || argField.IsComputed)
            {
                ctx.Error(nodeId, "CATALOG_DRIFT", $"הגדרת השדה המחושב \"{field.DisplayName}\" שגויה בקטלוג.");
                return null;
            }
            args.Add(new BoundField(target, joins, entity, argField));
        }

        return new BoundField(target, joins, entity, field) { ComputedArgs = args };
    }

    private object? ParseLiteral(JsonElement e, FieldDef field, string? nodeId, Ctx ctx)
    {
        object? result = field.DataType switch
        {
            DataType.String when e.ValueKind == JsonValueKind.String => e.GetString(),
            DataType.Enum when e.ValueKind == JsonValueKind.String => e.GetString(),
            DataType.Integer when e.ValueKind == JsonValueKind.Number && e.TryGetInt64(out var l) => l,
            DataType.Decimal when e.ValueKind == JsonValueKind.Number && e.TryGetDecimal(out var d) => d,
            DataType.Boolean when e.ValueKind is JsonValueKind.True or JsonValueKind.False => e.GetBoolean(),
            DataType.Date when e.ValueKind == JsonValueKind.String
                && DateOnly.TryParseExact(e.GetString(), "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.None, out var date)
                => date.ToDateTime(TimeOnly.MinValue),
            DataType.DateTime when e.ValueKind == JsonValueKind.String
                && DateTime.TryParse(e.GetString(), CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind, out var dt)
                => dt,
            _ => null,
        };

        if (result is null)
        {
            ctx.Error(nodeId, "INVALID_VALUE", $"הערך שהוזן אינו מתאים לשדה \"{field.DisplayName}\".");
            return null;
        }
        if (result is string s)
        {
            if (s.Length > _limits.MaxStringLength)
            {
                ctx.Error(nodeId, "VALUE_TOO_LONG", "הערך ארוך מדי.");
                return null;
            }
            if (field.DataType == DataType.Enum && field.EnumValues.All(v => v.Value != s))
            {
                ctx.Error(nodeId, "INVALID_ENUM_VALUE", $"הערך אינו אחד מהערכים המותרים לשדה \"{field.DisplayName}\".");
                return null;
            }
        }
        return result;
    }
}
