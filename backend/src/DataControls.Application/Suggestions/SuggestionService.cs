using System.Text.Json;
using DataControls.Application.Abstractions;
using DataControls.Application.Rules;
using DataControls.Domain.Catalog;
using DataControls.Domain.Rules.Ast;
using DataControls.Domain.Rules.Binding;
using DataControls.Domain.Rules.Explain;

namespace DataControls.Application.Suggestions;

// ---------- contract with the Python advisor service ----------

public sealed record AdvisorEnumValue(string Value, string DisplayName);
public sealed record AdvisorField(string Key, string DisplayName, string? Column, string DataType, bool IsNullable,
    bool IsRequiredByBusiness, bool IsSensitive, bool IsComputed, IReadOnlyList<AdvisorEnumValue> EnumValues);
public sealed record AdvisorRelationship(string Key, string ToEntity, string Cardinality, string FromColumn, string ToColumn, string DisplayName);
public sealed record AdvisorEntity(string Key, string DisplayName, string DisplayNamePlural, string Schema, string Table,
    string PrimaryKey, IReadOnlyList<AdvisorField> Fields, IReadOnlyList<AdvisorRelationship> Relationships);
public sealed record AdvisorRequest(int MaxSuggestions, IReadOnlyList<AdvisorEntity> Entities);

public sealed record AdvisorSuggestion(string Title, string ExplanationHe, string? Evidence, string Severity, JsonElement Definition, string? Source = null);
public sealed record AdvisorResponse(string Provider, bool FallbackUsed, IReadOnlyList<AdvisorSuggestion> Suggestions,
    string? Model = null, string? FallbackReason = null, int RejectedCount = 0);
public sealed record AdvisorHealth(string Status, string Provider, string? Model = null, bool Llm = false);

public interface IAdvisorClient
{
    Task<AdvisorResponse> SuggestAsync(AdvisorRequest request, CancellationToken ct);
    Task<AdvisorHealth?> HealthAsync(CancellationToken ct);
}

// ---------- persistence ----------

public static class SuggestionStatus
{
    public const string Proposed = "Proposed", Accepted = "Accepted", Rejected = "Rejected", Invalid = "Invalid";
}

public sealed class SuggestionRecord
{
    public Guid Id { get; set; }
    public Guid BatchId { get; set; }
    public string Provider { get; set; } = "";
    public string Title { get; set; } = "";
    public string ExplanationHe { get; set; } = "";
    public string? Evidence { get; set; }
    public string Severity { get; set; } = "Medium";
    public string DefinitionJson { get; set; } = "";
    public string Status { get; set; } = SuggestionStatus.Proposed;
    public string? ValidationErrors { get; set; }
    public DateTime CreatedAt { get; set; }
    public string? ReviewedBy { get; set; }
    public DateTime? ReviewedAt { get; set; }
    public Guid? AcceptedRuleId { get; set; }
}

public interface ISuggestionRepository
{
    Task InsertManyAsync(IReadOnlyList<SuggestionRecord> items, CancellationToken ct);
    Task<IReadOnlyList<SuggestionRecord>> ListAsync(Guid? batchId, string? status, CancellationToken ct);
    Task<SuggestionRecord?> GetAsync(Guid id, CancellationToken ct);
    Task UpdateReviewAsync(SuggestionRecord item, CancellationToken ct);
}

/// <param name="Source">"llm" when produced by a language model, "local" for the deterministic metadata/statistics engine.</param>
public sealed record SuggestionDto(Guid Id, Guid BatchId, string Provider, string Source, string? Model, string Title, string ExplanationHe,
    string? Evidence, string Severity, string? RootEntityName, IReadOnlyList<string> InvolvedFields, JsonElement Definition, string? SummaryHe,
    string Status, IReadOnlyList<ValidationError> ValidationErrors, DateTime CreatedAt, Guid? AcceptedRuleId);

public sealed record GenerateResultDto(Guid BatchId, string Provider, string? Model, bool IsLlm, bool FallbackUsed, string? FallbackReason,
    int Proposed, int Invalid, int Duplicates, int RejectedByAdvisor);

public sealed record AiStatusDto(bool Available, string? Provider, string? Model, bool IsLlm);

public sealed record AcceptSuggestionRequest(string? Name, JsonElement? Definition);

/// <summary>
/// AI suggestions: the LLM output is untrusted. Every suggestion goes through the SAME binder/validator as a rule
/// created by a user, is stored as "Proposed", and becomes a Draft rule only after explicit human approval.
/// </summary>
public sealed class SuggestionService(
    IAdvisorClient advisor,
    ISuggestionRepository suggestions,
    IRuleRepository rules,
    RuleService ruleService,
    ICatalogProvider catalog,
    IClock clock)
{
    public async Task<AiStatusDto> StatusAsync(CancellationToken ct)
    {
        var health = await advisor.HealthAsync(ct);
        return new AiStatusDto(health is not null, health?.Provider, health?.Model, health?.Llm ?? false);
    }

    public async Task<GenerateResultDto> GenerateAsync(int maxSuggestions, CancellationToken ct)
    {
        maxSuggestions = Math.Clamp(maxSuggestions, 1, 20);
        AdvisorResponse response;
        try
        {
            response = await advisor.SuggestAsync(new AdvisorRequest(maxSuggestions, ToAdvisorEntities(catalog.Current)), ct);
        }
        catch (Exception ex) when (ex is HttpRequestException or TaskCanceledException or JsonException)
        {
            throw new AppException("AI_UNAVAILABLE", 503, "שירות ההמלצות אינו זמין כרגע. שאר המערכת ממשיכה לפעול כרגיל.");
        }

        // a suggestion is a duplicate if it matches an existing rule OR a suggestion still waiting for review
        var existing = (await rules.ListAsync(new RuleQuery(null, null, null, 1, 1000), ct)).Items
            .Select(r => Canonical(r.DefinitionJson)).ToHashSet();
        foreach (var pending in await suggestions.ListAsync(null, SuggestionStatus.Proposed, ct))
            existing.Add(Canonical(pending.DefinitionJson));

        var batchId = Guid.NewGuid();
        var now = clock.UtcNow;
        var toStore = new List<SuggestionRecord>();
        int duplicates = 0;

        foreach (var s in response.Suggestions.Take(maxSuggestions))
        {
            var record = new SuggestionRecord
            {
                Id = Guid.NewGuid(), BatchId = batchId, Provider = ProviderLabel(response),
                Title = Clip(s.Title, 200), ExplanationHe = Clip(s.ExplanationHe, 2000), Evidence = s.Evidence is null ? null : Clip(s.Evidence, 1000),
                Severity = RuleSeverity.All.Contains(s.Severity) ? s.Severity : "Medium",
                DefinitionJson = s.Definition.GetRawText(), CreatedAt = now,
            };

            try
            {
                var def = RuleService.ParseDefinition(s.Definition);
                var bind = ruleService.Bind(def);
                if (!bind.IsValid)
                {
                    record.Status = SuggestionStatus.Invalid;
                    record.ValidationErrors = JsonSerializer.Serialize(bind.Errors, JsonSerializerOptions.Web);
                }
                else
                {
                    record.DefinitionJson = RuleJson.Serialize(def);
                    if (existing.Contains(record.DefinitionJson)) { duplicates++; continue; }
                    existing.Add(record.DefinitionJson);
                }
            }
            catch (AppException ex)
            {
                record.Status = SuggestionStatus.Invalid;
                record.ValidationErrors = JsonSerializer.Serialize(ex.Errors, JsonSerializerOptions.Web);
            }
            toStore.Add(record);
        }

        await suggestions.InsertManyAsync(toStore, ct);
        return new GenerateResultDto(batchId, response.Provider, response.Model, IsLlm(response.Provider), response.FallbackUsed, response.FallbackReason,
            toStore.Count(x => x.Status == SuggestionStatus.Proposed), toStore.Count(x => x.Status == SuggestionStatus.Invalid), duplicates,
            response.RejectedCount);
    }

    public async Task<IReadOnlyList<SuggestionDto>> ListAsync(Guid? batchId, string? status, CancellationToken ct)
    {
        var items = await suggestions.ListAsync(batchId, status, ct);
        return items.Select(ToDto).ToList();
    }

    public async Task<RuleRecord> AcceptAsync(Guid id, AcceptSuggestionRequest req, string user, CancellationToken ct)
    {
        var s = await suggestions.GetAsync(id, ct) ?? throw AppException.NotFound("ההצעה");
        if (s.Status != SuggestionStatus.Proposed)
            throw new AppException("SUGGESTION_NOT_PROPOSED", 409, "ניתן לאשר רק הצעה שממתינה לבדיקה.");

        var definition = req.Definition ?? JsonDocument.Parse(s.DefinitionJson).RootElement;
        // Accepted suggestions become DRAFT rules: running them is a separate, explicit user action.
        var rule = await ruleService.CreateAsync(
            new SaveRuleRequest(string.IsNullOrWhiteSpace(req.Name) ? s.Title : req.Name, s.ExplanationHe, RuleStatus.Draft, s.Severity, definition),
            user, origin: "AI", ct);

        s.Status = SuggestionStatus.Accepted;
        s.ReviewedBy = user;
        s.ReviewedAt = clock.UtcNow;
        s.AcceptedRuleId = rule.Id;
        await suggestions.UpdateReviewAsync(s, ct);
        return rule;
    }

    public async Task RejectAsync(Guid id, string user, CancellationToken ct)
    {
        var s = await suggestions.GetAsync(id, ct) ?? throw AppException.NotFound("ההצעה");
        if (s.Status != SuggestionStatus.Proposed)
            throw new AppException("SUGGESTION_NOT_PROPOSED", 409, "ניתן לדחות רק הצעה שממתינה לבדיקה.");
        s.Status = SuggestionStatus.Rejected;
        s.ReviewedBy = user;
        s.ReviewedAt = clock.UtcNow;
        await suggestions.UpdateReviewAsync(s, ct);
    }

    private SuggestionDto ToDto(SuggestionRecord s)
    {
        string? summary = null, entityName = null;
        IReadOnlyList<string> involved = [];
        try
        {
            var bind = ruleService.Bind(RuleJson.Parse(s.DefinitionJson));
            if (bind.IsValid)
            {
                summary = RuleDescriber.Summary(bind.Rule!);
                involved = RuleDescriber.InvolvedFields(bind.Rule!);
                entityName = bind.Rule!.Root.DisplayNamePlural;
            }
        }
        catch (JsonException) { }

        var errors = s.ValidationErrors is null
            ? new List<ValidationError>()
            : JsonSerializer.Deserialize<List<ValidationError>>(s.ValidationErrors, JsonSerializerOptions.Web) ?? new List<ValidationError>();
        var (provider, model) = SplitProvider(s.Provider);
        using var doc = JsonDocument.Parse(s.DefinitionJson);
        return new SuggestionDto(s.Id, s.BatchId, provider, IsLlm(provider) ? "llm" : "local", model, s.Title, s.ExplanationHe, s.Evidence,
            s.Severity, entityName, involved, doc.RootElement.Clone(), summary, s.Status, errors, s.CreatedAt, s.AcceptedRuleId);
    }

    /// <summary>The deterministic engine is never presented as an LLM.</summary>
    private static bool IsLlm(string provider) => !string.Equals(provider, "heuristic", StringComparison.OrdinalIgnoreCase);

    /// <summary>Stored as "provider" or "provider:model" (no schema change needed).</summary>
    private static string ProviderLabel(AdvisorResponse r) => string.IsNullOrEmpty(r.Model) ? r.Provider : $"{r.Provider}:{r.Model}";

    private static (string Provider, string? Model) SplitProvider(string label)
    {
        var i = label.IndexOf(':');
        return i < 0 ? (label, null) : (label[..i], label[(i + 1)..]);
    }

    private static string Canonical(string json)
    {
        try { return RuleJson.Serialize(RuleJson.Parse(json)); }
        catch (JsonException) { return json; }
    }

    private static string Clip(string s, int max) => s.Length > max ? s[..max] : s;

    /// <summary>
    /// The Python service needs physical names only for its read-only profiling queries (it re-validates them against
    /// INFORMATION_SCHEMA). Only business keys and Hebrew names are ever placed in the LLM prompt.
    /// </summary>
    private static IReadOnlyList<AdvisorEntity> ToAdvisorEntities(BusinessCatalog c) =>
        c.Entities.Values.Select(e => new AdvisorEntity(
            e.Key, e.DisplayName, e.DisplayNamePlural, e.SchemaName, e.TableName, e.PrimaryKeyColumn,
            e.Fields.Values.OrderBy(f => f.SortOrder).Select(f => new AdvisorField(
                f.Key, f.DisplayName, f.ColumnName, f.DataType.ToString(), f.IsNullable, f.IsRequiredByBusiness, f.IsSensitive, f.IsComputed,
                f.EnumValues.Select(v => new AdvisorEnumValue(v.Value, v.DisplayName)).ToList())).ToList(),
            e.Relationships.Values.Select(r => new AdvisorRelationship(
                r.Key, r.ToEntityKey, r.Cardinality.ToString(), r.FromColumn, r.ToColumn, r.DisplayName)).ToList()))
        .ToList();
}
