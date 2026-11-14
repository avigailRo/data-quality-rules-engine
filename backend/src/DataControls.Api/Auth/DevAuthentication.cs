using System.Security.Claims;
using System.Text.Encodings.Web;
using Microsoft.AspNetCore.Authentication;
using Microsoft.Extensions.Options;

namespace DataControls.Api.Auth;

public static class Policies
{
    public const string Viewer = nameof(Viewer);
    public const string RuleAuthor = nameof(RuleAuthor);
    public const string RuleRunner = nameof(RuleRunner);
    public const string CatalogAdmin = nameof(CatalogAdmin);
}

/// <summary>
/// DEMO authentication: the client selects one of three fixed users with the X-Demo-User header.
/// The authorization policies are real; in production this handler is replaced by OIDC/JWT
/// (e.g. Google Identity Platform) and roles come from the token.
/// </summary>
public sealed class DevAuthHandler(IOptionsMonitor<AuthenticationSchemeOptions> options, ILoggerFactory logger, UrlEncoder encoder)
    : AuthenticationHandler<AuthenticationSchemeOptions>(options, logger, encoder)
{
    public const string Scheme = "DemoUser";

    private static readonly Dictionary<string, (string Name, string[] Roles)> Users = new(StringComparer.OrdinalIgnoreCase)
    {
        ["admin"] = ("מנהל מערכת", [Policies.Viewer, Policies.RuleAuthor, Policies.RuleRunner, Policies.CatalogAdmin]),
        ["author"] = ("כותב בקרות", [Policies.Viewer, Policies.RuleAuthor, Policies.RuleRunner]),
        ["viewer"] = ("צופה", [Policies.Viewer]),
    };

    protected override Task<AuthenticateResult> HandleAuthenticateAsync()
    {
        if (!Request.Headers.TryGetValue("X-Demo-User", out var header) || string.IsNullOrWhiteSpace(header))
            return Task.FromResult(AuthenticateResult.NoResult());

        var userId = header.ToString();
        if (!Users.TryGetValue(userId, out var user))
            return Task.FromResult(AuthenticateResult.Fail("Unknown demo user"));

        var claims = new List<Claim> { new(ClaimTypes.NameIdentifier, userId.ToLowerInvariant()), new(ClaimTypes.Name, user.Name) };
        claims.AddRange(user.Roles.Select(r => new Claim(ClaimTypes.Role, r)));
        var principal = new ClaimsPrincipal(new ClaimsIdentity(claims, Scheme));
        return Task.FromResult(AuthenticateResult.Success(new AuthenticationTicket(principal, Scheme)));
    }
}

public static class UserExtensions
{
    public static string UserId(this ClaimsPrincipal user) => user.FindFirstValue(ClaimTypes.NameIdentifier) ?? "anonymous";
}
