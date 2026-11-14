using System.Globalization;
using DataControls.Domain.Catalog;
using DataControls.Domain.Rules.Ast;
using DataControls.Domain.Rules.Binding;

namespace DataControls.Domain.Rules.Explain;

public static class ValueFormatter
{
    private static readonly CultureInfo He = CultureInfo.GetCultureInfo("he-IL");

    public static string Format(FieldDef field, object? value)
    {
        if (value is null || value is DBNull) return "ריק";
        var text = value switch
        {
            bool b => b ? "כן" : "לא",
            DateTime d when field.DataType == DataType.DateTime => d.ToString("dd/MM/yyyy HH:mm", He),
            DateTime d => d.ToString("dd/MM/yyyy", He),
            DateOnly d => d.ToString("dd/MM/yyyy", He),
            decimal m => m.ToString("#,0.##", He),
            long or int or short => Convert.ToInt64(value, CultureInfo.InvariantCulture).ToString("#,0", He),
            string s when field.DataType == DataType.Enum => field.DisplayValueOf(s),
            string s => s.Length == 0 ? "ריק" : $"\"{s}\"",
            _ => Convert.ToString(value, CultureInfo.InvariantCulture) ?? "",
        };
        return field.Unit is { Length: > 0 } unit && value is decimal or long or int ? $"{text} {unit}" : text;
    }
}

/// <summary>Turns a bound rule into readable Hebrew. Used for the live summary sentence and for violation reasons.</summary>
public static class RuleDescriber
{
    /// <summary>Business names of every field a rule touches (used to show what an AI suggestion is based on).</summary>
    public static IReadOnlyList<string> InvolvedFields(BoundRule rule)
    {
        var names = new List<string>();
        void Visit(BoundNode node, string prefix)
        {
            switch (node)
            {
                case BoundGroup g: foreach (var ch in g.Children) Visit(ch, prefix); break;
                case BoundCollection c:
                    var childPrefix = $"{c.Relation.DisplayName} › ";
                    if (c.Condition is null) names.Add(c.Relation.DisplayName); else Visit(c.Condition, childPrefix);
                    break;
                case BoundComparison c:
                    names.Add(Name(c.Left, prefix));
                    if (c.Right is BoundField rf) names.Add(Name(rf, prefix));
                    break;
            }
        }
        static string Name(BoundField f, string prefix) =>
            f.Scope.Parent is null || prefix.Length == 0 ? f.DisplayName : prefix + f.DisplayName;
        Visit(rule.Condition, "");
        return names.Distinct().ToList();
    }

    public static string Summary(BoundRule rule) =>
        $"מצא {rule.Root.DisplayNamePlural} שבהם: {Describe(rule.Condition, top: true)}";

    public static string Describe(BoundNode node, bool top = false) => node switch
    {
        BoundComparison c => DescribeComparison(c, null),
        BoundCollection c => DescribeCollection(c),
        BoundGroup g => DescribeGroup(g, top),
        _ => "",
    };

    private static string DescribeGroup(BoundGroup g, bool top)
    {
        var joiner = g.Logic == LogicOp.And ? " וגם " : " או ";
        var inner = string.Join(joiner, g.Children.Select(ch => Describe(ch)));
        if (g.Negate) return $"לא מתקיים: ({inner})";
        return top || g.Children.Count == 1 ? inner : $"({inner})";
    }

    private static string DescribeCollection(BoundCollection c)
    {
        var where = c.Condition is null ? "" : $" שבה {Describe(c.Condition, top: true)}";
        return c.Quantifier switch
        {
            Quantifier.Any => $"קיימת לפחות רשומה אחת ב{c.Relation.DisplayName}{where}",
            Quantifier.None => $"אין אף רשומה ב{c.Relation.DisplayName}{where}",
            _ => $"בכל הרשומות ב{c.Relation.DisplayName} מתקיים: {(c.Condition is null ? "" : Describe(c.Condition, top: true))}",
        };
    }

    /// <param name="actual">When provided, actual values (by PathKey) are shown next to field names.</param>
    public static string DescribeComparison(BoundComparison c, IReadOnlyDictionary<string, object?>? actual)
    {
        var type = c.Left.DataType;
        var label = OperatorCatalog.LabelHe(c.Operator, type);
        var left = FieldText(c.Left, actual, quote: false);

        string rightText = c.Right switch
        {
            null => "",
            BoundLiteral l => ValueFormatter.Format(c.Left.Field, l.Value),
            BoundList l => "(" + string.Join(", ", l.Values.Select(v => ValueFormatter.Format(c.Left.Field, v))) + ")",
            BoundRange r => $"{ValueFormatter.Format(c.Left.Field, r.From)} ל־{ValueFormatter.Format(c.Left.Field, r.To)}",
            BoundField f => FieldText(f, actual, quote: true) + (f.Scope != c.Left.Scope ? $" של ה{f.Scope.Entity.DisplayName}" : ""),
            _ => "",
        };

        if (c.Right is null) return $"{left} {label}";
        var sep = label[^1] is 'ל' or 'מ' or 'ב' ? "־" : " ";
        return $"{left} {label}{sep}{rightText}";
    }

    private static string FieldText(BoundField f, IReadOnlyDictionary<string, object?>? actual, bool quote)
    {
        var name = quote ? $"\"{f.DisplayName}\"" : f.DisplayName;
        if (actual is not null && actual.TryGetValue(f.PathKey, out var v))
            return $"{name} ({ValueFormatter.Format(f.Field, v)})";
        return name;
    }
}

public sealed record ViolationReason(string ConditionId, string TextHe);

/// <summary>
/// Explains why a record is a violation: evaluates the AST in memory over the per-leaf flags computed by SQL
/// and returns the minimal set of satisfied conditions (for OR only the branches that matched).
/// </summary>
public static class ExplanationBuilder
{
    public static IReadOnlyList<ViolationReason> Explain(
        BoundRule rule, IReadOnlyDictionary<string, bool> flags, IReadOnlyDictionary<string, object?> values)
    {
        var reasons = new List<ViolationReason>();
        Collect(rule.Condition, flags, values, reasons);
        return reasons;
    }

    public static bool Evaluate(BoundNode node, IReadOnlyDictionary<string, bool> flags) => node switch
    {
        BoundGroup g => g.Negate ^ (g.Logic == LogicOp.And
            ? g.Children.All(ch => Evaluate(ch, flags))
            : g.Children.Any(ch => Evaluate(ch, flags))),
        _ => flags.TryGetValue(node.Id, out var v) && v,
    };

    private static void Collect(BoundNode node, IReadOnlyDictionary<string, bool> flags,
        IReadOnlyDictionary<string, object?> values, List<ViolationReason> reasons)
    {
        switch (node)
        {
            case BoundComparison c when Evaluate(c, flags):
                reasons.Add(new ViolationReason(c.Id, RuleDescriber.DescribeComparison(c, values)));
                break;
            case BoundCollection c when Evaluate(c, flags):
                reasons.Add(new ViolationReason(c.Id, RuleDescriber.Describe(c)));
                break;
            case BoundGroup g when g.Negate && Evaluate(g, flags):
                var inner = string.Join(g.Logic == LogicOp.And ? " וגם " : " או ", g.Children.Select(ch => RuleDescriber.Describe(ch)));
                reasons.Add(new ViolationReason(g.Id, $"לא מתקיים: ({inner})"));
                break;
            case BoundGroup g when Evaluate(g, flags):
                foreach (var child in g.Children)
                    if (g.Logic == LogicOp.And || Evaluate(child, flags))
                        Collect(child, flags, values, reasons);
                break;
        }
    }
}
