using System.Text.Json;
using DataControls.Application.Abstractions;
using DataControls.Domain.Rules.Ast;
using DataControls.Domain.Rules.Binding;
using DataControls.Domain.Rules.Explain;

namespace DataControls.Application.Rules;

public sealed record SaveRuleRequest(string Name, string? Description, string Status, string Severity, JsonElement Definition);

public sealed record ValidationResultDto(bool Valid, IReadOnlyList<ValidationError> Errors, string? SummaryHe);

public sealed record ColumnDto(string Key, string DisplayName);

public sealed record ViolationDto(string RecordKey, string DisplayLabel, IReadOnlyList<ViolationReason> Reasons, IReadOnlyDictionary<string, string> Values);

public sealed record PreviewResultDto(long TotalCount, IReadOnlyList<ColumnDto> Columns, IReadOnlyList<ViolationDto> Items);

/// <summary>Builds the stored / displayed violation from an executed row (explanation + formatted values).</summary>
public static class ViolationFactory
{
    public static IReadOnlyList<ColumnDto> Columns(BoundRule rule) =>
        rule.DisplayFields.Select(f => new ColumnDto(f.PathKey, f.DisplayName)).ToList();

    public static ViolationDto ToDto(BoundRule rule, ExecutedRow row)
    {
        var reasons = ExplanationBuilder.Explain(rule, row.Flags, row.Values);
        var values = new Dictionary<string, string>();
        foreach (var f in rule.DisplayFields)
            values[f.PathKey] = ValueFormatter.Format(f.Field, row.Values.GetValueOrDefault(f.PathKey));

        var labelField = rule.Root.Fields[rule.Root.DisplayFieldKey];
        var label = $"{ValueFormatter.Format(labelField, row.Label).Trim('"')} (#{row.Key})";
        return new ViolationDto(row.Key, label, reasons, values);
    }

    public static ViolationRecord ToRecord(ViolationDto dto, int seq)
    {
        var search = string.Join(' ', new[] { dto.DisplayLabel }
            .Concat(dto.Values.Values)
            .Concat(dto.Reasons.Select(r => r.TextHe)));
        return new ViolationRecord
        {
            Seq = seq,
            RecordKey = dto.RecordKey,
            DisplayLabel = dto.DisplayLabel.Length > 400 ? dto.DisplayLabel[..400] : dto.DisplayLabel,
            ReasonsJson = JsonSerializer.Serialize(dto.Reasons, JsonSerializerOptions.Web),
            FailedConditionIds = "," + string.Join(',', dto.Reasons.Select(r => r.ConditionId)) + ",",
            ValuesJson = JsonSerializer.Serialize(dto.Values, JsonSerializerOptions.Web),
            SearchText = search.Length > 2000 ? search[..2000] : search,
        };
    }
}

public sealed class RuleService(
    IRuleRepository rules,
    ICatalogProvider catalog,
    IRuleQueryExecutor executor,
    IClock clock)
{
    public const int PreviewRows = 20;

    public static RuleDefinition ParseDefinition(JsonElement element)
    {
        try
        {
            return element.Deserialize<RuleDefinition>(RuleJson.Options)
                   ?? throw new JsonException("empty");
        }
        catch (JsonException ex)
        {
            throw new AppException("RULE_VALIDATION_FAILED", 400, "מבנה הגדרת הבקרה אינו תקין.",
                [new ValidationError(null, "INVALID_JSON", $"מבנה ההגדרה אינו תקין: {ex.Message}")]);
        }
    }

    public BindResult Bind(RuleDefinition def) => new RuleBinder(catalog.Current).Bind(def);

    public BoundRule BindOrThrow(RuleDefinition def)
    {
        var result = Bind(def);
        if (!result.IsValid) throw AppException.Validation(result.Errors);
        return result.Rule!;
    }

    public ValidationResultDto Validate(JsonElement definition)
    {
        RuleDefinition def;
        try { def = ParseDefinition(definition); }
        catch (AppException ex) { return new ValidationResultDto(false, ex.Errors, null); }

        var result = Bind(def);
        return new ValidationResultDto(result.IsValid, result.Errors, result.IsValid ? RuleDescriber.Summary(result.Rule!) : null);
    }

    public Task<PagedResultRecord<RuleRecord>> ListAsync(RuleQuery q, CancellationToken ct) => rules.ListAsync(q, ct);

    public async Task<RuleRecord> GetAsync(Guid id, CancellationToken ct) =>
        await rules.GetAsync(id, ct) ?? throw AppException.NotFound("הבקרה");

    public string? SummaryOf(RuleRecord r)
    {
        try
        {
            var result = Bind(RuleJson.Parse(r.DefinitionJson));
            return result.IsValid ? RuleDescriber.Summary(result.Rule!) : null;
        }
        catch (JsonException) { return null; }
    }

    public Task<IReadOnlyList<RuleVersionRecord>> VersionsAsync(Guid id, CancellationToken ct) => rules.GetVersionsAsync(id, ct);

    public async Task<RuleRecord> CreateAsync(SaveRuleRequest req, string user, string origin, CancellationToken ct)
    {
        ValidateHeader(req, allowArchived: false);
        var def = ParseDefinition(req.Definition);
        BindOrThrow(def);

        var now = clock.UtcNow;
        var rule = new RuleRecord
        {
            Id = Guid.NewGuid(),
            Name = req.Name.Trim(),
            Description = req.Description?.Trim(),
            RootEntityKey = def.RootEntity,
            DefinitionJson = RuleJson.Serialize(def),
            Status = req.Status,
            Severity = req.Severity,
            Origin = origin,
            CurrentVersion = 1,
            CreatedBy = user, CreatedAt = now, UpdatedBy = user, UpdatedAt = now,
        };
        await rules.InsertAsync(rule, ct);
        return rule;
    }

    public async Task<RuleRecord> UpdateAsync(Guid id, SaveRuleRequest req, int expectedVersion, string user, CancellationToken ct)
    {
        var existing = await GetAsync(id, ct);
        if (existing.Status == RuleStatus.Archived)
            throw new AppException("RULE_ARCHIVED", 409, "לא ניתן לערוך בקרה שהועברה לארכיון.");
        if (existing.CurrentVersion != expectedVersion)
            throw new AppException("CONCURRENCY_CONFLICT", 412, "הבקרה עודכנה על ידי משתמש אחר. רעננו את הדף ונסו שוב.");

        ValidateHeader(req, allowArchived: false);
        var def = ParseDefinition(req.Definition);
        BindOrThrow(def);

        existing.Name = req.Name.Trim();
        existing.Description = req.Description?.Trim();
        existing.RootEntityKey = def.RootEntity;
        existing.DefinitionJson = RuleJson.Serialize(def);
        existing.Status = req.Status;
        existing.Severity = req.Severity;
        existing.CurrentVersion = expectedVersion + 1;
        existing.UpdatedBy = user;
        existing.UpdatedAt = clock.UtcNow;

        if (!await rules.UpdateAsync(existing, expectedVersion, ct))
            throw new AppException("CONCURRENCY_CONFLICT", 412, "הבקרה עודכנה על ידי משתמש אחר. רעננו את הדף ונסו שוב.");
        return existing;
    }

    public async Task<RuleRecord> DuplicateAsync(Guid id, string user, CancellationToken ct)
    {
        var source = await GetAsync(id, ct);
        var now = clock.UtcNow;
        var copy = new RuleRecord
        {
            Id = Guid.NewGuid(),
            Name = Truncate($"{source.Name} (עותק)", 200),
            Description = source.Description,
            RootEntityKey = source.RootEntityKey,
            DefinitionJson = source.DefinitionJson,
            Status = RuleStatus.Draft,
            Severity = source.Severity,
            Origin = source.Origin,
            CurrentVersion = 1,
            CreatedBy = user, CreatedAt = now, UpdatedBy = user, UpdatedAt = now,
        };
        await rules.InsertAsync(copy, ct);
        return copy;
    }

    public async Task ArchiveAsync(Guid id, string user, CancellationToken ct)
    {
        await GetAsync(id, ct);
        await rules.SetStatusAsync(id, RuleStatus.Archived, user, clock.UtcNow, ct);
    }

    public async Task<PreviewResultDto> PreviewAsync(JsonElement definition, CancellationToken ct)
    {
        var bound = BindOrThrow(ParseDefinition(definition));
        try
        {
            var result = await executor.ExecuteAsync(bound, PreviewRows, ct);
            return new PreviewResultDto(result.TotalCount, ViolationFactory.Columns(bound),
                result.Rows.Select(r => ViolationFactory.ToDto(bound, r)).ToList());
        }
        catch (QueryTimeoutException)
        {
            throw new AppException("QUERY_TIMEOUT", 408, "התצוגה המקדימה חרגה מזמן הריצה המותר. נסו לצמצם את התנאים.");
        }
    }

    public async Task<CompiledSqlView> GetSqlAsync(Guid id, CancellationToken ct)
    {
        var rule = await GetAsync(id, ct);
        return executor.Explain(BindOrThrow(RuleJson.Parse(rule.DefinitionJson)), 10_000);
    }

    private static void ValidateHeader(SaveRuleRequest req, bool allowArchived)
    {
        var errors = new List<ValidationError>();
        if (string.IsNullOrWhiteSpace(req.Name)) errors.Add(new(null, "NAME_REQUIRED", "יש להזין שם לבקרה."));
        else if (req.Name.Length > 200) errors.Add(new(null, "NAME_TOO_LONG", "שם הבקרה ארוך מדי (עד 200 תווים)."));
        if (req.Description is { Length: > 1000 }) errors.Add(new(null, "DESCRIPTION_TOO_LONG", "התיאור ארוך מדי (עד 1000 תווים)."));
        string[] statuses = allowArchived ? RuleStatus.All : new[] { RuleStatus.Draft, RuleStatus.Active };
        if (!statuses.Contains(req.Status)) errors.Add(new(null, "INVALID_STATUS", "סטטוס לא חוקי."));
        if (!RuleSeverity.All.Contains(req.Severity)) errors.Add(new(null, "INVALID_SEVERITY", "רמת חומרה לא חוקית."));
        if (errors.Count > 0) throw AppException.Validation(errors);
    }

    private static string Truncate(string s, int max) => s.Length > max ? s[..max] : s;
}
