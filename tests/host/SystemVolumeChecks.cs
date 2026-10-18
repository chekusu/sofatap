using System.Text;
using System.Text.Json;
using System.Diagnostics;
using SofaTap;

internal static class SystemVolumeChecks
{
    internal static void Run(Action<bool, string> check)
    {
        ActionMessage Parse(string fields) => Protocol.Parse(Encoding.UTF8.GetBytes(
            "{\"id\":\"" + Guid.NewGuid() + "\",\"type\":\"volume\"," + fields + "}"));
        foreach (var command in new[] { "up", "down", "mute" })
            check(Parse("\"command\":\"" + command + "\"").Command == command, "strict volume command " + command);
        foreach (var fields in new[] { "\"command\":\"toggle\"", "\"command\":\"UP\"", "\"command\":null",
            "\"command\":1", "\"command\":[]", "\"command\":\"up\",\"command\":\"down\"",
            "\"command\":\"up\",\"amount\":5", "\"command\":\"up;exec\"", "\"key\":\"up\"" })
        {
            try { Parse(fields); check(false, "reject malformed volume action"); }
            catch (Exception error) when (error is ProtocolException or JsonException) { check(true, "reject malformed volume action"); }
        }

        var input = new Input(); var volume = new Volume();
        var session = new ActionSession(input, systemVolume: volume);
        var action = Parse("\"command\":\"up\"");
        check(session.Execute(action).Ok && volume.Writes == 1 && input.Actions == 0, "volume bypasses keyboard and pointer injection");
        check(session.Execute(action).Ok && session.Execute(action with { Id = action.Id.ToUpperInvariant() }).Ok && volume.Writes == 1,
            "volume UUID deduplicates including UUID casing");
        check(!session.Execute(action with { Command = "mute" }).Ok && volume.Writes == 1, "UUID cannot change volume command");
        volume.Fail = true;
        var failed = action with { Id = Guid.NewGuid().ToString("D") };
        var failedAck = session.Execute(failed);
        check(!failedAck.Ok && failedAck.Error!.StartsWith("volume_unknown:") && volume.Writes == 2, "volume uncertainty is explicit");
        volume.Fail = false;
        check(session.Execute(failed) == failedAck && volume.Writes == 2, "failed volume command never retries after recovery");
        input.Available = false;
        check(!session.Execute(action with { Id = Guid.NewGuid().ToString("D") }).Ok && volume.Writes == 2, "locked desktop blocks volume before backend");
        input.Available = true;
        check(!new ActionSession(input).Execute(action).Ok && input.Actions == 0, "legacy session rejects volume without fake success");
        check(SystemVolume.Create(true) is null, "dry-run does not create an audio provider");

        using var live = new LiveTextSession(new Editor(), () => true);
        var liveActions = new ActionSession(input, liveText: live, systemVolume: volume);
        var begin = liveActions.Execute(new(Guid.NewGuid().ToString("D"), "textBegin")).LiveText!;
        liveActions.Execute(action with { Id = Guid.NewGuid().ToString("D") });
        check(liveActions.Execute(new(Guid.NewGuid().ToString("D"), "textSync", Text: "edited", Session: begin.Session,
            Revision: 1, SelectionStart: 6)).Ok, "volume preserves the active live-text session");
        var ready = JsonSerializer.SerializeToElement(ReceiverServer.CreateHello("Fixture", "windows", false, "ready",
            new("unknown", 0), systemVolumeSupported: true), LiveTextWire.Options);
        check(ready.GetProperty("systemVolume").GetProperty("version").GetInt32() == 1 &&
            ready.GetProperty("systemVolume").EnumerateObject().Count() == 1, "volume capability contains only a version, never fabricated volume state");
        foreach (var status in new[] { "ready", "dry_run", "desktop_unavailable" })
        {
            var hello = JsonSerializer.SerializeToElement(ReceiverServer.CreateHello("Fixture", "macos", status == "dry_run",
                status, new("unknown", 0), systemVolumeSupported: status != "ready"), LiveTextWire.Options);
            check(!hello.TryGetProperty("systemVolume", out _), "legacy dry-run and unavailable hello omit usable volume support");
        }
        EndpointChecks(check);
        MacChecks(check);
        CacheChecks(check);
    }

    private static void EndpointChecks(Action<bool, string> check)
    {
        var endpoint = new Endpoint(); var opens = 0;
        var windows = new WindowsSystemVolume(() => { opens++; return endpoint; });
        check(windows.Available && endpoint.Writes == 0 && endpoint.Disposals == 1, "Windows adapter availability only reads and releases default endpoint");
        windows.Apply("up"); check(Math.Abs(endpoint.Levels[0] - .55f) < .00001f && !endpoint.Mutes[0], "Windows master volume increases five points without changing mute");
        endpoint.Levels = [.99f]; windows.Apply("up"); check(endpoint.Levels[0] == 1, "volume caps at one hundred percent");
        var writes = endpoint.Writes; windows.Apply("up"); check(endpoint.Writes == writes, "volume at ceiling is a successful no-op");
        endpoint.Levels = [.01f]; windows.Apply("down"); check(endpoint.Levels[0] == 0, "volume floors at zero");
        writes = endpoint.Writes; windows.Apply("down"); check(endpoint.Writes == writes, "volume at floor is a successful no-op");
        windows.Apply("mute"); check(endpoint.Mutes[0], "mute toggles off to on");
        windows.Apply("mute"); check(!endpoint.Mutes[0], "mute toggles on to off");
        var before = opens;
        Reject(() => windows.Apply("exec"), "volume_unsupported", check, "adapter rejects invalid command before opening audio");
        check(before == opens, "unknown command never touches endpoint");
        endpoint.FailRead = true;
        check(!windows.Available, "read failure withdraws capability");
        writes = endpoint.Writes;
        Reject(() => windows.Apply("up"), "volume_unavailable", check, "read failure rejects action before mutation");
        check(endpoint.Writes == writes, "failed read never writes audio");
        endpoint.FailRead = false;
        foreach (var invalid in new[] { float.NaN, float.PositiveInfinity, -.1f, 1.1f })
        {
            endpoint.Levels = [invalid]; check(!windows.Available, "invalid native scalar withdraws capability");
        }
        endpoint.Levels = [.5f]; endpoint.FailWrite = true;
        Reject(() => windows.Apply("up"), "volume_unknown", check, "native set failure is uncertain and not retried");
        endpoint.FailWrite = false; endpoint.Levels = [.5f, .7f]; endpoint.Mutes = [false, false]; endpoint.FailAtWrite = endpoint.Writes + 2;
        Reject(() => windows.Apply("down"), "volume_unknown", check, "partial multi-channel change never rolls back");
        check(Math.Abs(endpoint.Levels[0] - (.5f / .7f * .65f)) < .00001f && endpoint.Levels[1] == .7f, "partial channel failure does not replay earlier channel");
        var replacement = new Endpoint { Levels = [.2f] }; var useReplacement = false;
        var changed = new WindowsSystemVolume(() => useReplacement ? replacement : endpoint);
        check(changed.Available, "initial default output is probed");
        useReplacement = true; changed.Apply("up");
        check(Math.Abs(replacement.Levels[0] - .25f) < .00001f, "each new action resolves the current default output");
        foreach (var (levels, command, expected) in new (float[], string, float[])[]
        {
            ([.5f, .25f], "up", [.55f, .275f]),
            ([.5f, .25f], "down", [.45f, .225f]),
            ([.5f, 0], "up", [.55f, 0]),
            ([0, .5f], "down", [0, .45f]),
            ([.98f, .49f], "up", [1, .5f]),
            ([.02f, .01f], "down", [0, 0]),
            ([0, 0], "up", [.05f, .05f]),
            ([0, 0], "down", [0, 0]),
            ([1, .5f], "up", [1, .5f])
        })
        {
            var channels = new Endpoint { Levels = [.. levels], Mutes = [false, false] };
            new EndpointSystemVolume(() => channels).Apply(command);
            check(channels.Levels.Zip(expected).All(pair => Math.Abs(pair.First - pair.Second) < .00001f),
                "channel volume scales relative balance at zero, ceiling and lower boundary");
            check(!channels.Mutes[0] && !channels.Mutes[1], "level adjustment never changes mute state");
        }
    }

    private static void MacChecks(Action<bool, string> check)
    {
        var api = new MacApi(); var mac = new MacSystemVolume(api);
        check(mac.Available && api.Writes.Count == 0 && api.ReadDevices.All(value => value == 42), "Mac availability probes writable default-output master controls only");
        mac.Apply("up"); check(Math.Abs(api.Levels[0] - .55f) < .00001f && api.Writes.Single() == (42u, MacAudioEndpoint.Volume, 0u), "Mac routes volume to native master property");
        mac.Apply("mute"); check(api.Mutes[0] && api.Writes[^1] == (42u, MacAudioEndpoint.Mute, 0u), "Mac routes mute to native output property");
        api.Device = 43; mac.Apply("down"); check(api.Writes[^1].Device == 43, "Mac resolves changed default output on next action");
        api.Master = false; api.Levels = new() { [1] = .2f, [2] = .6f }; api.Mutes = new() { [1] = false, [2] = false };
        api.Writes.Clear(); mac.Apply("up");
        check(api.Writes.Select(value => value.Element).SequenceEqual([1u, 2u]) &&
            Math.Abs(api.Levels[2] - .65f) < .00001f && Math.Abs(api.Levels[2] / api.Levels[1] - 3) < .00001f,
            "Mac channel controls retain relative balance rather than absolute difference");
        api.Levels = new() { [1] = .5f, [2] = 0 }; api.Writes.Clear(); mac.Apply("up");
        check(Math.Abs(api.Levels[1] - .55f) < .00001f && api.Levels[2] == 0 && api.Writes.Count == 1,
            "Mac preserves a deliberately silent channel without writing it");
        mac.Apply("mute"); check(api.Mutes.Values.All(value => value), "Mac channel mute affects every output channel");
        api.Unsupported = true;
        check(!mac.Available, "Mac fixed-volume or missing mute output does not advertise support");
        var writes = api.Writes.Count;
        Reject(() => mac.Apply("down"), "volume_unavailable", check, "unsupported Mac output fails before writes");
        check(api.Writes.Count == writes, "Mac does not approximate unsupported output with focus-dependent keys");
        api.Unsupported = false; api.Device = 0;
        check(!mac.Available, "missing Mac default output withdraws capability");
        var buffer = new byte[40]; BitConverter.GetBytes(2u).CopyTo(buffer, 0);
        BitConverter.GetBytes(2u).CopyTo(buffer, 8); BitConverter.GetBytes(1u).CopyTo(buffer, 24);
        check(MacAudioApi.ChannelCount(buffer, 8) == 3, "CoreAudio 64-bit AudioBufferList alignment");
        try { MacAudioApi.ChannelCount(buffer[..24], 8); check(false, "reject truncated stream config"); }
        catch (IOException) { check(true, "reject truncated stream config"); }
    }

    private static void Reject(Action action, string code, Action<bool, string> check, string name)
    {
        try { action(); check(false, name); }
        catch (InputInjectionException error) { check(error.Message.StartsWith(code + ":", StringComparison.Ordinal), name); }
    }
    private static void CacheChecks(Action<bool, string> check)
    {
        using var entered = new ManualResetEventSlim();
        using var release = new ManualResetEventSlim();
        using var finished = new ManualResetEventSlim();
        var source = new BlockedVolume(entered, release, finished);
        long now = Stopwatch.GetTimestamp();
        using var cached = new CachedSystemVolume(source, TimeSpan.FromMilliseconds(1), TimeSpan.FromSeconds(2), () => Interlocked.Read(ref now));
        try
        {
            check(SpinWait.SpinUntil(() => cached.Available, 2000), "background audio probe publishes first support result");
            Interlocked.Add(ref now, Stopwatch.Frequency * 3);
            check(!cached.Available && entered.Wait(TimeSpan.FromSeconds(2)), "stale audio support expires while refresh blocks");
            var watch = Stopwatch.StartNew();
            var stayedUnavailable = true;
            for (var index = 0; index < 1000; index++) stayedUnavailable &= !cached.Available;
            check(stayedUnavailable && watch.Elapsed < TimeSpan.FromMilliseconds(250) && source.Probes == 2,
                "cached capability is nonblocking and cannot pile up probe tasks");
            watch.Restart();
            Reject(() => cached.Apply("up"), "volume_busy", check, "stalled capability probe cannot queue a late volume mutation");
            check(watch.Elapsed < TimeSpan.FromMilliseconds(250), "explicit volume does not wait indefinitely behind audio probe");
            cached.Dispose();
            check(!cached.Available, "disposed audio capability is unavailable without waiting for probe");
        }
        finally { release.Set(); }
        check(finished.Wait(TimeSpan.FromSeconds(2)), "blocked read-only probe can finish after disposal");
    }
    private sealed class BlockedVolume(ManualResetEventSlim entered, ManualResetEventSlim release, ManualResetEventSlim finished) : ISystemVolume
    {
        internal int Probes;
        public bool Available
        {
            get
            {
                if (Interlocked.Increment(ref Probes) > 1)
                {
                    entered.Set(); release.Wait(); finished.Set();
                }
                return true;
            }
        }
        public void Apply(string command) => throw new InvalidOperationException("No real audio in capability test.");
    }
    private sealed class Input : IInputInjector
    {
        public bool Available { get; set; } = true;
        public int Actions;
        public void Apply(ActionMessage action) => Actions++;
        public void ReleaseAll() { }
    }
    private sealed class Volume : ISystemVolume
    {
        public bool Available => true;
        internal int Writes;
        internal bool Fail;
        public void Apply(string command) { Writes++; if (Fail) throw new InputInjectionException("volume_unknown: fixture"); }
    }
    private sealed class Endpoint : ISystemVolumeEndpoint
    {
        internal float[] Levels = [.5f]; internal bool[] Mutes = [false];
        internal int Writes, Disposals, FailAtWrite;
        internal bool FailRead, FailWrite;
        public float[] ReadLevels() => FailRead ? throw new IOException("private audio diagnostic") : [.. Levels];
        public bool[] ReadMutes() => [.. Mutes];
        public void SetLevel(int index, float level) { Write(); Levels[index] = level; }
        public void SetMute(int index, bool muted) { Write(); Mutes[index] = muted; }
        private void Write() { Writes++; if (FailWrite || Writes == FailAtWrite) throw new IOException("private audio diagnostic"); }
        public void Dispose() => Disposals++;
    }
    private sealed class MacApi : IMacAudioApi
    {
        internal uint Device = 42;
        internal bool Master = true, Unsupported;
        internal Dictionary<uint, float> Levels = new() { [0] = .5f };
        internal Dictionary<uint, bool> Mutes = new() { [0] = false };
        internal List<uint> ReadDevices = [];
        internal List<(uint Device, uint Selector, uint Element)> Writes = [];
        public uint DefaultOutputDevice() => Device;
        public int OutputChannelCount(uint device) => 2;
        public bool Writable(uint device, uint selector, uint element) => !Unsupported && (Master ? element == 0 : element is 1 or 2);
        public float ReadLevel(uint device, uint element) { ReadDevices.Add(device); return Levels[element]; }
        public bool ReadMute(uint device, uint element) { ReadDevices.Add(device); return Mutes[element]; }
        public void WriteLevel(uint device, uint element, float level) { Writes.Add((device, MacAudioEndpoint.Volume, element)); Levels[element] = level; }
        public void WriteMute(uint device, uint element, bool muted) { Writes.Add((device, MacAudioEndpoint.Mute, element)); Mutes[element] = muted; }
    }
    private sealed class Editor : ILiveTextEditor
    {
        private TextEditorSnapshot _state = new("fixture", "text", 4, 0);
        public TextEditorSnapshot Read() => _state;
        public TextEditorSnapshot Replace(TextEditorSnapshot expected, string text, int selectionStart, int selectionLength) =>
            _state = new("fixture", text, selectionStart, selectionLength);
        public void Dispose() { }
    }
}
