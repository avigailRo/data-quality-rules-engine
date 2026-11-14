using System.Net.Http.Json;
using System.Text.Json;
using DataControls.Application.Suggestions;
using Microsoft.Extensions.Options;

namespace DataControls.Infrastructure.Advisor;

public sealed class AdvisorOptions
{
    public string BaseUrl { get; set; } = "http://127.0.0.1:8000";
    public int TimeoutSeconds { get; set; } = 60;
    /// <summary>Shared secret between the API and the internal Python service.</summary>
    public string ServiceToken { get; set; } = "dev-internal-token";
}

/// <summary>Client for the internal Python advisor. Timeouts are short-circuited so the rest of the system never waits on AI.</summary>
public sealed class HttpAdvisorClient(HttpClient http, IOptions<AdvisorOptions> options) : IAdvisorClient
{
    public async Task<AdvisorResponse> SuggestAsync(AdvisorRequest request, CancellationToken ct)
    {
        using var msg = new HttpRequestMessage(HttpMethod.Post, "internal/v1/suggestions")
        {
            Content = JsonContent.Create(request, options: JsonSerializerOptions.Web),
        };
        msg.Headers.Add("X-Service-Token", options.Value.ServiceToken);
        using var response = await http.SendAsync(msg, ct);
        response.EnsureSuccessStatusCode();
        return await response.Content.ReadFromJsonAsync<AdvisorResponse>(JsonSerializerOptions.Web, ct)
               ?? throw new JsonException("Empty advisor response");
    }

    public async Task<AdvisorHealth?> HealthAsync(CancellationToken ct)
    {
        try
        {
            using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
            cts.CancelAfter(TimeSpan.FromSeconds(5));
            return await http.GetFromJsonAsync<AdvisorHealth>("health", JsonSerializerOptions.Web, cts.Token);
        }
        catch (Exception ex) when (ex is HttpRequestException or TaskCanceledException or JsonException)
        {
            return null;
        }
    }
}
