using System.Diagnostics;
using SofaTap;

internal static class MacPermissionChecks
{
    // Failure modes: slow native preflight blocks movement; concurrent readers fan
    // out native calls; a stale positive sample survives a hung/revoked provider;
    // provider exceptions grant access; disposal blocks or leaves access enabled.
    internal static void Run(Action<bool, string> check)
    {
        using var entered = new ManualResetEventSlim();
        using var release = new ManualResetEventSlim();
        using var finished = new ManualResetEventSlim();
        var calls = 0;
        long now = Stopwatch.GetTimestamp();
        using var cache = new CachedMacPostPermission(() =>
        {
            if (Interlocked.Increment(ref calls) == 1) return true;
            entered.Set();
            release.Wait();
            finished.Set();
            return false;
        }, interval: TimeSpan.FromMilliseconds(1), maxAge: TimeSpan.FromMilliseconds(250),
           clock: () => Interlocked.Read(ref now));
        check(entered.Wait(TimeSpan.FromSeconds(2)), "permission provider reached blocked second query");
        try
        {
            check(cache.IsAllowed, "fresh positive permission is available without native requery");
            var watch = Stopwatch.StartNew();
            var allAllowed = true;
            for (var i = 0; i < 10000; i++) allAllowed &= cache.IsAllowed;
            check(allAllowed, "cached movement permission remains available during native query");
            check(watch.Elapsed < TimeSpan.FromMilliseconds(100), "10000 permission reads never wait on blocked native provider");
            check(calls == 2, "hot-path reads cannot create more permission queries");
            Interlocked.Add(ref now, Stopwatch.Frequency);
            check(!cache.IsAllowed, "stale positive permission expires while native provider is stuck");
            watch.Restart();
            cache.Dispose();
            check(watch.Elapsed < TimeSpan.FromMilliseconds(100) && !cache.IsAllowed, "disposal is bounded and fails closed");
        }
        finally { release.Set(); }
        check(finished.Wait(TimeSpan.FromSeconds(2)), "blocked provider exits when released");

        using var queried = new ManualResetEventSlim();
        using var failing = new CachedMacPostPermission(() => { queried.Set(); throw new InvalidOperationException(); });
        check(queried.Wait(TimeSpan.FromSeconds(2)) && !failing.IsAllowed, "native permission exceptions never allow input");
        var sink = new RecordingMacSink();
        var input = new MacInput(sink);
        input.Apply(new("", "button", Button: "left", Down: true));
        input.Dispose();
        check(sink.HeldButtons.Count == 0 && !input.Available, "disposal releases owned input before closing permission monitor");
        var posts = sink.Events.Count;
        input.Dispose(); input.ReleaseAll();
        try { input.Apply(new("", "move", Dx: 10, Dy: 0)); check(false, "disposed input must reject movement"); }
        catch (InputInjectionException) { check(sink.Events.Count == posts, "disposed input cannot post new events"); }
        Console.WriteLine("PASS Mac permission cache: slow-provider, freshness, exception and disposal checks; no OS input");
    }
}
