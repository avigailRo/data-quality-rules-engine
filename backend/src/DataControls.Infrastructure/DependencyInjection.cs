using DataControls.Application.Abstractions;
using DataControls.Application.Rules;
using DataControls.Application.Runs;
using DataControls.Application.Suggestions;
using DataControls.Infrastructure.Advisor;
using DataControls.Infrastructure.Persistence;
using DataControls.Infrastructure.Runs;
using DataControls.Infrastructure.SqlServer;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Options;

namespace DataControls.Infrastructure;

public static class DependencyInjection
{
    public static IServiceCollection AddDataControls(this IServiceCollection services, IConfiguration config)
    {
        services.Configure<DatabaseOptions>(config.GetSection("Database"));
        services.Configure<AdvisorOptions>(config.GetSection("Advisor"));

        services.AddSingleton<IClock, SystemClock>();
        services.AddSingleton<ICatalogProvider, SqlCatalogProvider>();
        services.AddSingleton<ICatalogVerifier, SqlCatalogVerifier>();
        services.AddSingleton<IRuleQueryExecutor, SqlServerRuleQueryExecutor>();
        services.AddSingleton<IRuleRepository, SqlRuleRepository>();
        services.AddSingleton<IRunRepository, SqlRunRepository>();
        services.AddSingleton<ISuggestionRepository, SqlSuggestionRepository>();
        services.AddSingleton<IRunQueue, ChannelRunQueue>();
        services.AddSingleton(sp => new RunExecutionSettings(sp.GetRequiredService<IOptions<DatabaseOptions>>().Value.MaxStoredViolations));

        services.AddScoped<RuleService>();
        services.AddScoped<RunService>();
        services.AddScoped<SuggestionService>();

        services.AddHttpClient<IAdvisorClient, HttpAdvisorClient>((sp, http) =>
        {
            var o = sp.GetRequiredService<IOptions<AdvisorOptions>>().Value;
            http.BaseAddress = new Uri(o.BaseUrl.TrimEnd('/') + "/");
            http.Timeout = TimeSpan.FromSeconds(o.TimeoutSeconds);
        });

        services.AddHostedService<CatalogWarmup>();
        services.AddHostedService<RunWorker>();
        return services;
    }
}
