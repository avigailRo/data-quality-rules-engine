using DataControls.Domain.Catalog;
using DataControls.Domain.Rules.Ast;

namespace DataControls.Domain.Rules;

public enum OperandShape { None, Single, List, Range }

/// <summary>Operator x type matrix with Hebrew labels. The UI receives it from the API, so the rules live in one place.</summary>
public static class OperatorCatalog
{
    private static readonly Operator[] Comparable = [Operator.Eq, Operator.Neq, Operator.Gt, Operator.Gte, Operator.Lt, Operator.Lte];

    public static IReadOnlyList<Operator> AllowedFor(DataType type) => type switch
    {
        DataType.String => [Operator.Eq, Operator.Neq, Operator.In, Operator.NotIn, Operator.Contains, Operator.StartsWith, Operator.EndsWith, Operator.IsEmpty, Operator.IsNotEmpty],
        DataType.Integer or DataType.Decimal => [.. Comparable, Operator.Between, Operator.In, Operator.NotIn, Operator.IsEmpty, Operator.IsNotEmpty],
        DataType.Date or DataType.DateTime => [.. Comparable, Operator.Between, Operator.IsEmpty, Operator.IsNotEmpty],
        DataType.Boolean => [Operator.Eq, Operator.Neq, Operator.IsEmpty, Operator.IsNotEmpty],
        DataType.Enum => [Operator.Eq, Operator.Neq, Operator.In, Operator.NotIn, Operator.IsEmpty, Operator.IsNotEmpty],
        _ => [],
    };

    /// <summary>Operators that may compare a field to another field.</summary>
    public static bool AllowsFieldComparison(Operator op, DataType type) =>
        type == DataType.Boolean ? op is Operator.Eq or Operator.Neq : Comparable.Contains(op);

    public static OperandShape ShapeOf(Operator op) => op switch
    {
        Operator.IsEmpty or Operator.IsNotEmpty => OperandShape.None,
        Operator.In or Operator.NotIn => OperandShape.List,
        Operator.Between => OperandShape.Range,
        _ => OperandShape.Single,
    };

    public static bool IsTemporal(DataType t) => t is DataType.Date or DataType.DateTime;

    public static bool IsNumeric(DataType t) => t is DataType.Integer or DataType.Decimal;

    /// <summary>Type compatibility for field-to-field comparisons.</summary>
    public static bool AreCompatible(DataType a, DataType b) =>
        a == b
        || (IsNumeric(a) && IsNumeric(b))
        || (IsTemporal(a) && IsTemporal(b))
        || (a is DataType.String or DataType.Enum && b is DataType.String or DataType.Enum);

    public static string LabelHe(Operator op, DataType type) => op switch
    {
        Operator.Eq => "שווה ל",
        Operator.Neq => "שונה מ",
        Operator.Gt => IsTemporal(type) ? "מאוחר מ" : "גדול מ",
        Operator.Gte => IsTemporal(type) ? "מאוחר או שווה ל" : "גדול או שווה ל",
        Operator.Lt => IsTemporal(type) ? "מוקדם מ" : "קטן מ",
        Operator.Lte => IsTemporal(type) ? "מוקדם או שווה ל" : "קטן או שווה ל",
        Operator.Between => "בין",
        Operator.In => "אחד מ",
        Operator.NotIn => "אינו אחד מ",
        Operator.Contains => "מכיל",
        Operator.StartsWith => "מתחיל ב",
        Operator.EndsWith => "מסתיים ב",
        Operator.IsEmpty => "ריק",
        Operator.IsNotEmpty => "אינו ריק",
        _ => op.ToString(),
    };
}
