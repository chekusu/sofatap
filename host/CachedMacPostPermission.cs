using System.Diagnostics;

namespace SofaTap;

/// CGPreflightPostEventAccess is an IPC permission query, not a cheap flag read.
/// Keep it off the event path. Lock/login state and AX trust are still checked
/// synchronously for each event; an expired/missing permission sample denies input.
internal sealed class CachedMacPostPermission : IDisposable
{
    private readonly object _gate = new();
    private readonly ManualResetEventSlim _stop = new();
    private readonly TimeSpan _maxAge;
    private readonly TimeSpan _interval;
    private readonly Func<long> _clock;
    private bool _allowed, _hasSample, _disposed;
    private long _sampledAt;

    internal CachedMacPostPermission(Func<bool> query, TimeSpan? interval = null,
        TimeSpan? maxAge = null, Func<long>? clock = null)
    {
        _interval = interval ?? TimeSpan.FromMilliseconds(100);
        _maxAge = maxAge ?? TimeSpan.FromMilliseconds(250);
        _clock = clock ?? Stopwatch.GetTimestamp;
        new Thread(() => Poll(query)) { IsBackground = true, Name = "Sofatap post-event permission" }.Start();
    }

    internal bool IsAllowed
    {
        get
        {
            lock (_gate)
                return !_disposed && _hasSample && _allowed &&
                    Stopwatch.GetElapsedTime(_sampledAt, _clock()) <= _maxAge;
        }
    }

    private void Poll(Func<bool> query)
    {
        try
        {
            while (!_stop.IsSet)
            {
                var started = _clock();
                bool allowed;
                try { allowed = query(); }
                catch (Exception) { allowed = false; }
                lock (_gate)
                {
                    if (_disposed) break;
                    // Age from query start so a slow provider cannot refresh stale access.
                    _allowed = allowed; _sampledAt = started; _hasSample = true;
                }
                if (_stop.Wait(_interval)) break;
            }
        }
        finally { _stop.Dispose(); }
    }

    public void Dispose()
    {
        lock (_gate)
        {
            if (_disposed) return;
            _disposed = true;
            try { _stop.Set(); } catch (ObjectDisposedException) { }
        }
        // A native provider may hang; never block event/session teardown waiting for it.
    }
}
