using Dapper;
using DataControls.Application.Abstractions;
using DataControls.Domain.Catalog;
using DataControls.Infrastructure.SqlServer;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Options;

namespace DataControls.Infrastructure.Persistence;

/// <summary>Loads the business metadata catalog from schema dq and keeps an immutable in-memory snapshot.</summary>
public sealed class SqlCatalogProvider(IOptions<DatabaseOptions> options) : ICatalogProvider
{
    private volatile BusinessCatalog? _current;
    private readonly SemaphoreSlim _lock = new(1, 1);

    public BusinessCatalog Current => _current ?? throw new InvalidOperationException("Catalog not loaded yet");

    internal sealed record EntityRow(int Id, string Key, string DisplayName, string DisplayNamePlural, string? Description,
        string SchemaName, string TableName, string PrimaryKeyColumn, string DisplayFieldKey);
    internal sealed record FieldRow(int Id, int EntityId, string Key, string DisplayName, string? Description, string? ColumnName,
        string DataType, bool IsNullable, bool IsRequiredByBusiness, bool IsSensitive, string? Unit, int? MaxLength,
        string? ComputedFunction, string? ComputedArgFieldKey, int SortOrder);
    internal sealed record EnumRow(int FieldId, string Value, string DisplayName);
    internal sealed record RelRow(int FromEntityId, string Key, int ToEntityId, string Cardinality, string FromColumn, string ToColumn, string DisplayName);

    public async Task ReloadAsync(CancellationToken ct = default)
    {
        await _lock.WaitAsync(ct);
        try
        {
            await using var conn = new SqlConnection(options.Value.ConnectionString);
            var entities = (await conn.QueryAsync<EntityRow>(
                "SELECT Id, [Key], DisplayName, DisplayNamePlural, Description, SchemaName, TableName, PrimaryKeyColumn, DisplayFieldKey FROM dq.Entity WHERE IsActive = 1")).ToList();
            var fields = (await conn.QueryAsync<FieldRow>(
                "SELECT Id, EntityId, [Key], DisplayName, Description, ColumnName, DataType, IsNullable, IsRequiredByBusiness, IsSensitive, Unit, MaxLength, ComputedFunction, ComputedArgFieldKey, SortOrder FROM dq.Field WHERE IsActive = 1")).ToList();
            var enums = (await conn.QueryAsync<EnumRow>("SELECT FieldId, Value, DisplayName FROM dq.EnumValue ORDER BY SortOrder")).ToList();
            var rels = (await conn.QueryAsync<RelRow>(
                "SELECT FromEntityId, [Key], ToEntityId, Cardinality, FromColumn, ToColumn, DisplayName FROM dq.Relationship WHERE IsActive = 1")).ToList();

            var keyById = entities.ToDictionary(e => e.Id, e => e.Key);
            var defs = entities.Select(e => new EntityDef
            {
                Key = e.Key,
                DisplayName = e.DisplayName,
                DisplayNamePlural = e.DisplayNamePlural,
                Description = e.Description,
                SchemaName = e.SchemaName,
                TableName = e.TableName,
                PrimaryKeyColumn = e.PrimaryKeyColumn,
                DisplayFieldKey = e.DisplayFieldKey,
                Fields = fields.Where(f => f.EntityId == e.Id).ToDictionary(f => f.Key, f => new FieldDef
                {
                    Key = f.Key,
                    DisplayName = f.DisplayName,
                    Description = f.Description,
                    ColumnName = f.ColumnName,
                    DataType = Enum.Parse<DataType>(f.DataType),
                    IsNullable = f.IsNullable,
                    IsRequiredByBusiness = f.IsRequiredByBusiness,
                    IsSensitive = f.IsSensitive,
                    Unit = f.Unit,
                    MaxLength = f.MaxLength,
                    ComputedFunction = f.ComputedFunction,
                    ComputedArgFieldKeys = f.ComputedArgFieldKey?.Split(',', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries) ?? [],
                    EnumValues = enums.Where(v => v.FieldId == f.Id).Select(v => new EnumValueDef(v.Value, v.DisplayName)).ToList(),
                    SortOrder = f.SortOrder,
                }, StringComparer.Ordinal),
                Relationships = rels.Where(r => r.FromEntityId == e.Id && keyById.ContainsKey(r.ToEntityId)).ToDictionary(r => r.Key, r => new RelationshipDef
                {
                    Key = r.Key,
                    FromEntityKey = e.Key,
                    ToEntityKey = keyById[r.ToEntityId],
                    Cardinality = Enum.Parse<Cardinality>(r.Cardinality),
                    FromColumn = r.FromColumn,
                    ToColumn = r.ToColumn,
                    DisplayName = r.DisplayName,
                }, StringComparer.Ordinal),
            });

            _current = new BusinessCatalog(defs);
        }
        finally
        {
            _lock.Release();
        }
    }
}

/// <summary>
/// Verifies the catalog against the real database schema (sys.columns): every table/column exists, the entity lives in
/// schema biz, the "one" side of every relationship is unique. Metadata is the identifier allowlist, so it must be true.
/// </summary>
public sealed class SqlCatalogVerifier(IOptions<DatabaseOptions> options) : ICatalogVerifier
{
    internal sealed record ColumnRow(string SchemaName, string TableName, string ColumnName, bool IsNullable, bool IsUnique);

    public async Task<IReadOnlyList<CatalogIssue>> VerifyAsync(BusinessCatalog catalog, CancellationToken ct = default)
    {
        await using var conn = new SqlConnection(options.Value.ConnectionString);
        var cols = (await conn.QueryAsync<ColumnRow>(@"
            SELECT s.name AS SchemaName, t.name AS TableName, c.name AS ColumnName, c.is_nullable AS IsNullable,
                   CAST(CASE WHEN EXISTS (
                        SELECT 1 FROM sys.index_columns ic JOIN sys.indexes i ON i.object_id = ic.object_id AND i.index_id = ic.index_id
                        WHERE ic.object_id = c.object_id AND ic.column_id = c.column_id AND i.is_unique = 1
                          AND (SELECT COUNT(*) FROM sys.index_columns x WHERE x.object_id = i.object_id AND x.index_id = i.index_id) = 1)
                   THEN 1 ELSE 0 END AS BIT) AS IsUnique
            FROM sys.columns c JOIN sys.tables t ON t.object_id = c.object_id JOIN sys.schemas s ON s.schema_id = t.schema_id
            WHERE s.name = N'biz'")).ToList();

        var lookup = cols.ToDictionary(c => (c.TableName.ToLowerInvariant(), c.ColumnName.ToLowerInvariant()));
        var issues = new List<CatalogIssue>();

        foreach (var e in catalog.Entities.Values)
        {
            if (e.SchemaName != "biz")
            {
                issues.Add(new(e.Key, null, $"הישות מצביעה על הסכמה '{e.SchemaName}' – מותרת רק הסכמה biz."));
                continue;
            }
            bool Has(string table, string col) => lookup.ContainsKey((table.ToLowerInvariant(), col.ToLowerInvariant()));

            if (!Has(e.TableName, e.PrimaryKeyColumn))
                issues.Add(new(e.Key, null, $"הטבלה או עמודת המפתח אינן קיימות ({e.TableName}.{e.PrimaryKeyColumn})."));

            foreach (var f in e.Fields.Values)
            {
                if (f.IsComputed)
                {
                    if (!FunctionCatalog.Functions.ContainsKey(f.ComputedFunction!))
                        issues.Add(new(e.Key, f.Key, $"הפונקציה '{f.ComputedFunction}' אינה בקטלוג הפונקציות."));
                    continue;
                }
                if (f.ColumnName is null || !lookup.TryGetValue((e.TableName.ToLowerInvariant(), f.ColumnName.ToLowerInvariant()), out var col))
                    issues.Add(new(e.Key, f.Key, $"העמודה '{f.ColumnName}' אינה קיימת בטבלה {e.TableName}."));
                else if (col.IsNullable && !f.IsNullable)
                    issues.Add(new(e.Key, f.Key, "העמודה מאפשרת NULL אך מוגדרת בקטלוג כחובה – סמנטיקת ה־NULL תהיה שגויה."));
            }

            foreach (var r in e.Relationships.Values)
            {
                if (!catalog.Entities.TryGetValue(r.ToEntityKey, out var target)) continue;
                if (!Has(e.TableName, r.FromColumn) || !Has(target.TableName, r.ToColumn))
                {
                    issues.Add(new(e.Key, r.Key, "עמודות הקשר אינן קיימות."));
                    continue;
                }
                var oneSide = r.Cardinality == Cardinality.ManyToOne
                    ? lookup[(target.TableName.ToLowerInvariant(), r.ToColumn.ToLowerInvariant())]
                    : lookup[(e.TableName.ToLowerInvariant(), r.FromColumn.ToLowerInvariant())];
                if (!oneSide.IsUnique)
                    issues.Add(new(e.Key, r.Key, "צד ה'אחד' של הקשר אינו ייחודי – עלולות להיווצר כפילויות."));
            }
        }
        return issues;
    }
}
