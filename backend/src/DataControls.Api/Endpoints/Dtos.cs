using System.Text.Json;
using DataControls.Application.Rules;
using DataControls.Domain.Catalog;
using DataControls.Domain.Rules;
using DataControls.Domain.Rules.Ast;

namespace DataControls.Api.Endpoints;

// Catalog DTOs expose business keys and Hebrew names ONLY - never schema, table or column names.
public sealed record EnumValueDto(string Value, string DisplayName);
public sealed record FieldDto(string Key, string DisplayName, string? Description, string DataType, bool IsNullable,
    bool IsRequiredByBusiness, string? Unit, bool IsComputed, IReadOnlyList<EnumValueDto> EnumValues);
public sealed record RelationshipDto(string Key, string DisplayName, string ToEntity, string Cardinality);
public sealed record EntityDto(string Key, string DisplayName, string DisplayNamePlural, string? Description, string DisplayFieldKey,
    IReadOnlyList<FieldDto> Fields, IReadOnlyList<RelationshipDto> Relationships);
public sealed record OperatorDto(string Op, string LabelHe, string Shape, bool AllowsField);
public sealed record TypeOperatorsDto(string DataType, IReadOnlyList<OperatorDto> Operators);

public sealed record EntityRefDto(string Key, string DisplayName);
public sealed record LastRunDto(Guid Id, string Status, long? ViolationCount, DateTime? FinishedAt);
public sealed record RuleDto(Guid Id, string Name, string? Description, EntityRefDto RootEntity, JsonElement Definition, string? SummaryHe,
    string Status, string Severity, string Origin, int Version, LastRunDto? LastRun,
    string CreatedBy, DateTime CreatedAt, string UpdatedBy, DateTime UpdatedAt);
public sealed record RuleVersionDto(int VersionNo, string Name, string CreatedBy, DateTime CreatedAt);

public static class DtoMapper
{
    public static EntityDto ToDto(EntityDef e) => new(
        e.Key, e.DisplayName, e.DisplayNamePlural, e.Description, e.DisplayFieldKey,
        e.Fields.Values.OrderBy(f => f.SortOrder).Select(f => new FieldDto(
            f.Key, f.DisplayName, f.Description, Camel(f.DataType.ToString()), f.IsNullable, f.IsRequiredByBusiness, f.Unit, f.IsComputed,
            f.EnumValues.Select(v => new EnumValueDto(v.Value, v.DisplayName)).ToList())).ToList(),
        e.Relationships.Values.Select(r => new RelationshipDto(r.Key, r.DisplayName, r.ToEntityKey, Camel(r.Cardinality.ToString()))).ToList());

    public static IReadOnlyList<TypeOperatorsDto> Operators() =>
        Enum.GetValues<DataType>().Select(t => new TypeOperatorsDto(
            Camel(t.ToString()),
            OperatorCatalog.AllowedFor(t).Select(op => new OperatorDto(
                Camel(op.ToString()), OperatorCatalog.LabelHe(op, t), Camel(OperatorCatalog.ShapeOf(op).ToString()),
                OperatorCatalog.AllowsFieldComparison(op, t))).ToList())).ToList();

    public static RuleDto ToDto(RuleRecord r, BusinessCatalog catalog, string? summary)
    {
        using var doc = JsonDocument.Parse(r.DefinitionJson);
        var entityName = catalog.FindEntity(r.RootEntityKey)?.DisplayNamePlural ?? r.RootEntityKey;
        return new RuleDto(r.Id, r.Name, r.Description, new EntityRefDto(r.RootEntityKey, entityName), doc.RootElement.Clone(), summary,
            r.Status, r.Severity, r.Origin, r.CurrentVersion,
            r.LastRunId is null ? null : new LastRunDto(r.LastRunId.Value, r.LastRunStatus ?? "", r.LastRunViolationCount, r.LastRunFinishedAt),
            r.CreatedBy, r.CreatedAt, r.UpdatedBy, r.UpdatedAt);
    }

    public static string Camel(string s) => string.IsNullOrEmpty(s) ? s : char.ToLowerInvariant(s[0]) + s[1..];
}
