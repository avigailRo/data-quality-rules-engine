namespace DataControls.Domain.Catalog;

public enum DataType { String, Integer, Decimal, Date, DateTime, Boolean, Enum }

public enum Cardinality { ManyToOne, OneToMany }

public sealed record EnumValueDef(string Value, string DisplayName);

/// <summary>A business field. Physical column name is known only to the SQL compiler.</summary>
public sealed class FieldDef
{
    public required string Key { get; init; }
    public required string DisplayName { get; init; }
    public string? Description { get; init; }
    /// <summary>Physical column; null for computed fields.</summary>
    public string? ColumnName { get; init; }
    public required DataType DataType { get; init; }
    public bool IsNullable { get; init; }
    public bool IsRequiredByBusiness { get; init; }
    public bool IsSensitive { get; init; }
    public string? Unit { get; init; }
    public int? MaxLength { get; init; }
    /// <summary>Name of a function from the closed <see cref="FunctionCatalog"/>.</summary>
    public string? ComputedFunction { get; init; }
    public IReadOnlyList<string> ComputedArgFieldKeys { get; init; } = [];
    public IReadOnlyList<EnumValueDef> EnumValues { get; init; } = [];
    public int SortOrder { get; init; }

    public bool IsComputed => ComputedFunction is not null;

    public string DisplayValueOf(string raw) =>
        DataType == DataType.Enum
            ? EnumValues.FirstOrDefault(v => v.Value == raw)?.DisplayName ?? raw
            : raw;
}

public sealed class RelationshipDef
{
    public required string Key { get; init; }
    public required string FromEntityKey { get; init; }
    public required string ToEntityKey { get; init; }
    public required Cardinality Cardinality { get; init; }
    /// <summary>Column on the "from" table (FK for ManyToOne, PK for OneToMany).</summary>
    public required string FromColumn { get; init; }
    /// <summary>Column on the "to" table (PK for ManyToOne, FK for OneToMany).</summary>
    public required string ToColumn { get; init; }
    public required string DisplayName { get; init; }
}

public sealed class EntityDef
{
    public required string Key { get; init; }
    public required string DisplayName { get; init; }
    public required string DisplayNamePlural { get; init; }
    public string? Description { get; init; }
    public required string SchemaName { get; init; }
    public required string TableName { get; init; }
    public required string PrimaryKeyColumn { get; init; }
    public required string DisplayFieldKey { get; init; }
    public required IReadOnlyDictionary<string, FieldDef> Fields { get; init; }
    public required IReadOnlyDictionary<string, RelationshipDef> Relationships { get; init; }
}

/// <summary>Immutable snapshot of the business metadata catalog. Also the identifier allowlist.</summary>
public sealed class BusinessCatalog
{
    public BusinessCatalog(IEnumerable<EntityDef> entities)
    {
        Entities = entities.ToDictionary(e => e.Key, StringComparer.Ordinal);
    }

    public IReadOnlyDictionary<string, EntityDef> Entities { get; }

    public EntityDef? FindEntity(string key) => Entities.GetValueOrDefault(key);
}

/// <summary>Closed catalog of functions usable in computed fields. Adding one is a language extension (code), not a rule.</summary>
public static class FunctionCatalog
{
    public static readonly IReadOnlyDictionary<string, (DataType[] Args, DataType Returns)> Functions =
        new Dictionary<string, (DataType[], DataType)>(StringComparer.Ordinal)
        {
            ["ageYears"] = ([DataType.Date], DataType.Integer),
            ["fullName"] = ([DataType.String, DataType.String], DataType.String),
        };
}
