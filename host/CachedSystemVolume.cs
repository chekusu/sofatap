using System.Diagnostics;

namespace SofaTap;

// Capability discovery is optional and cannot block the pointer/text control loop.
// At most one read-only probe runs, even if a native audio service never returns.
internal sealed class CachedSystemVolume : ISystemVolume, IDisposable
{
    private sealed record Snapshot(bool Supported, long CompletedAt);
    private readonly ISystemVolume _source;
    private readonly Func<long> _now;
    private readonly long _refreshTicks, _maximumAgeTicks;
    private readonly object _sourceGate = new();
    private Snapshot _snapshot = new(false, 0);
    private long _lastStarted;
    private int _probing, _disposed;

    internal CachedSystemVolume(ISystemVolume source, TimeSpan? refresh = null, TimeSpan? maximumAge = null, Func<long>? now = null)
    {
        _source = source;
        _now = now ?? Stopwatch.GetTimestamp;
        _refreshTicks = (long)((refresh ?? TimeSpan.FromSeconds(1)).TotalSeconds * Stopwatch.Frequency);
        _maximumAgeTicks = (long)((maximumAge ?? TimeSpan.FromSeconds(3)).TotalSeconds * Stopwatch.Frequency);
        Schedule(_now());
    }
    public bool Available
    {
        get
        {
            if (Volatile.Read(ref _disposed) != 0) return false;
            var now = _now();
            if (now - Interlocked.Read(ref _lastStarted) >= _refreshTicks) Schedule(now);
            var snapshot = Volatile.Read(ref _snapshot);
            return snapshot.Supported && now - snapshot.CompletedAt <= _maximumAgeTicks;
        }
    }
    public void Apply(string command)
    {
        if (Volatile.Read(ref _disposed) != 0) throw new InputInjectionException("volume_unavailable: Receiver audio control has stopped.");
        // Explicit actions still resolve and validate the current default output;
        // the cached capability never grants permission to use a stale endpoint.
        // A slow background probe must not queue a future mutation behind it.
        // The UUID failure is cached by ActionSession; only a fresh user action
        // may try again once the output becomes responsive.
        if (!Monitor.TryEnter(_sourceGate, 50))
            throw new InputInjectionException("volume_busy: Audio output is still being checked. Try again shortly.");
        try { _source.Apply(command); }
        finally { Monitor.Exit(_sourceGate); }
    }
    private void Schedule(long now)
    {
        if (Volatile.Read(ref _disposed) != 0 || Interlocked.CompareExchange(ref _probing, 1, 0) != 0) return;
        Interlocked.Exchange(ref _lastStarted, now);
        _ = Task.Run(() =>
        {
            var supported = false;
            try { lock (_sourceGate) supported = _source.Available; }
            catch (Exception) { /* Optional capability failures stay hidden and cannot stop input. */ }
            finally
            {
                if (Volatile.Read(ref _disposed) == 0)
                    Volatile.Write(ref _snapshot, new(supported, _now()));
                Interlocked.Exchange(ref _probing, 0);
            }
        });
    }
    public void Dispose() => Interlocked.Exchange(ref _disposed, 1);
}
