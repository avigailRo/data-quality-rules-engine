using System.Threading.Channels;
using DataControls.Application.Abstractions;
using DataControls.Application.Rules;
using DataControls.Application.Runs;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;

namespace DataControls.Infrastructure.Runs;

/// <summary>In-process queue. Behind IRunQueue so it can be replaced by Cloud Tasks / Pub/Sub without touching use cases.</summary>
public sealed class ChannelRunQueue : IRunQueue
{
    private readonly Channel<Guid> _channel = Channel.CreateBounded<Guid>(new BoundedChannelOptions(500) { FullMode = BoundedChannelFullMode.Wait });

    public ValueTask EnqueueAsync(Guid runId, CancellationToken ct = default) => _channel.Writer.WriteAsync(runId, ct);

    public IAsyncEnumerable<Guid> ReadAllAsync(CancellationToken ct) => _channel.Reader.ReadAllAsync(ct);
}

public sealed class RunWorker(IRunQueue queue, IServiceScopeFactory scopes, ICatalogProvider catalog, IClock clock, ILogger<RunWorker> logger)
    : BackgroundService
{
    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        // Runs that were queued/running when the process stopped cannot be resumed from an in-memory queue.
        using (var scope = scopes.CreateScope())
        {
            var interrupted = await scope.ServiceProvider.GetRequiredService<IRunRepository>().FailInterruptedRunsAsync(clock.UtcNow, stoppingToken);
            if (interrupted > 0) logger.LogWarning("Marked {Count} interrupted runs as failed", interrupted);
        }

        await foreach (var runId in queue.ReadAllAsync(stoppingToken))
        {
            try
            {
                using var scope = scopes.CreateScope();
                await scope.ServiceProvider.GetRequiredService<RunService>().ExecuteAsync(runId, stoppingToken);
            }
            catch (Exception ex) when (ex is not OperationCanceledException)
            {
                logger.LogError(ex, "Unexpected failure processing run {RunId}", runId);
            }
        }
    }
}

/// <summary>Loads the catalog once at startup so the API fails fast if the database is not reachable.</summary>
public sealed class CatalogWarmup(ICatalogProvider catalog) : IHostedService
{
    public Task StartAsync(CancellationToken cancellationToken) => catalog.ReloadAsync(cancellationToken);
    public Task StopAsync(CancellationToken cancellationToken) => Task.CompletedTask;
}

public sealed class SystemClock : IClock
{
    public DateTime UtcNow => DateTime.UtcNow;
}
