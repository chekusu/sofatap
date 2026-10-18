using SofaTap;

internal static class LinuxVolumeChecks
{
    private const string Wpctl = "/usr/bin/wpctl", Pactl = "/usr/bin/pactl", WpDefault = "@DEFAULT_AUDIO_SINK@", WpSink = "42", PulseSink = "alsa_output.pci-0000_00_1f.3.analog-stereo";
    private static LinuxVolumeResult Ok(string output = "") => new(true, 0, output);
    private static readonly LinuxVolumeResult Timeout = new(false, -1, "");

    internal static void Run(Action<bool, string> check)
    {
        // Every backend operation below goes through this fake; no audio tools are launched.
        var probe = new FakeRunner(check, new Step(Wpctl, ["inspect", WpDefault], Ok("id 42, type PipeWire:Interface:Node\n  media.class = \"Audio/Sink\"")),
                new Step(Wpctl, ["get-volume", WpSink], Ok("Volume: 0.50 [MUTED]\n")));
        check(new LinuxSystemVolume(probe, Wpctl, Pactl).Available, "Linux volume read-only WirePlumber probe");
        probe.Done();

        foreach (var (current, command, target) in new[]
        {
            ("0.50", "up", "0.55"), ("0.50", "down", "0.45"),
            ("0.98", "up", "1"), ("0.03", "down", "0"),
            ("1.50", "down", "1"), ("1.50", "up", "1"), ("0.00", "down", "0")
        })
        {
            var runner = new FakeRunner(check,
                new Step(Wpctl, ["inspect", WpDefault], Ok("id 42, type PipeWire:Interface:Node\n  media.class = \"Audio/Sink\"")),
                new Step(Wpctl, ["get-volume", WpSink], Ok($"Volume: {current} [MUTED]\n")),
                new Step(Wpctl, ["set-volume", WpSink, target], Ok()));
            new LinuxSystemVolume(runner, Wpctl, Pactl).Apply(command);
            runner.Done();
        }
        foreach (var muted in new[] { "", " [MUTED]" })
        {
            var runner = new FakeRunner(check,
                new Step(Wpctl, ["inspect", WpDefault], Ok("id 42, type PipeWire:Interface:Node\n  media.class = \"Audio/Sink\"")),
                new Step(Wpctl, ["get-volume", WpSink], Ok("Volume: 0.50" + muted)),
                new Step(Wpctl, ["set-mute", WpSink, "toggle"], Ok()));
            new LinuxSystemVolume(runner, Wpctl, Pactl).Apply("mute");
            runner.Done();
        }

        var pulseProbe = new FakeRunner(check,
            new Step(Pactl, ["get-default-sink"], Ok(PulseSink + "\n")),
                new Step(Pactl, ["get-sink-volume", PulseSink], Ok(Pulse(32768, 16384))),
            new Step(Pactl, ["get-sink-mute", PulseSink], Ok("Mute: no\n")));
        check(new LinuxSystemVolume(pulseProbe, null, Pactl).Available, "Linux volume PulseAudio requires both read probes");
        pulseProbe.Done();
        foreach (var (left, right, command, targetLeft, targetRight) in new[]
        {
            (32768u, 16384u, "up", "36045", "19661"),
            (65000u, 1000u, "up", "65536", "4277"),
            (65000u, 1000u, "down", "61723", "0"),
            (98304u, 65536u, "down", "65536", "62259")
        })
        {
            var runner = new FakeRunner(check,
                new Step(Pactl, ["get-default-sink"], Ok(PulseSink + "\n")),
                new Step(Pactl, ["get-sink-volume", PulseSink], Ok(Pulse(left, right))),
                new Step(Pactl, ["get-sink-mute", PulseSink], Ok("Mute: yes")),
                new Step(Pactl, ["set-sink-volume", PulseSink, targetLeft, targetRight], Ok()));
            new LinuxSystemVolume(runner, null, Pactl).Apply(command);
            runner.Done();
        }
        foreach (var muted in new[] { "yes", "no" })
        {
            var runner = new FakeRunner(check,
                new Step(Pactl, ["get-default-sink"], Ok(PulseSink + "\n")),
                new Step(Pactl, ["get-sink-volume", PulseSink], Ok(Pulse(32768, 32768))),
                new Step(Pactl, ["get-sink-mute", PulseSink], Ok("Mute: " + muted)),
                new Step(Pactl, ["set-sink-mute", PulseSink, "toggle"], Ok()));
            new LinuxSystemVolume(runner, null, Pactl).Apply("mute");
            runner.Done();
        }

        // Backend fallback is permitted only before a mutation, after an unsuccessful read.
        foreach (var failure in new[] { Timeout, new LinuxVolumeResult(true, 1, "Volume: 0.50"), Ok("unrecognized") })
        {
            var runner = new FakeRunner(check,
                new Step(Wpctl, ["inspect", WpDefault], Ok("id 42, type PipeWire:Interface:Node\n  media.class = \"Audio/Sink\"")),
                new Step(Wpctl, ["get-volume", WpSink], failure),
                new Step(Pactl, ["get-default-sink"], Ok(PulseSink + "\n")),
                new Step(Pactl, ["get-sink-volume", PulseSink], Ok(Pulse(32768, 32768))),
                new Step(Pactl, ["get-sink-mute", PulseSink], Ok("Mute: no")),
                new Step(Pactl, ["set-sink-mute", PulseSink, "toggle"], Ok()));
            new LinuxSystemVolume(runner, Wpctl, Pactl).Apply("mute");
            runner.Done();
        }
        foreach (var failure in new[] { Timeout, new LinuxVolumeResult(true, 1, "") })
        {
            var runner = new FakeRunner(check,
                new Step(Wpctl, ["inspect", WpDefault], Ok("id 42, type PipeWire:Interface:Node\n  media.class = \"Audio/Sink\"")),
                new Step(Wpctl, ["get-volume", WpSink], Ok("Volume: 0.50")),
                new Step(Wpctl, ["set-mute", WpSink, "toggle"], failure));
            ExpectFailure(new LinuxSystemVolume(runner, Wpctl, Pactl), "mute", "volume_unknown:", check);
            runner.Done(); // No pactl fallback or second toggle after an uncertain mutation.
        }
        var lostPulse = new FakeRunner(check,
            new Step(Pactl, ["get-default-sink"], Ok(PulseSink + "\n")),
                new Step(Pactl, ["get-sink-volume", PulseSink], Ok(Pulse(32768, 32768))),
            new Step(Pactl, ["get-sink-mute", PulseSink], Ok("Mute: no")),
            new Step(Pactl, ["set-sink-volume", PulseSink, "36045", "36045"], Timeout));
        ExpectFailure(new LinuxSystemVolume(lostPulse, null, Pactl), "up", "volume_unknown:", check);
        lostPulse.Done();

        var missing = new FakeRunner(check);
        var noTools = new LinuxSystemVolume(missing, null, null);
        check(!noTools.Available, "Linux volume missing tools are unavailable");
        ExpectFailure(noTools, "up", "volume_unavailable:", check);
        missing.Done();
        var unsafePaths = new FakeRunner(check);
        check(!new LinuxSystemVolume(unsafePaths, "wpctl", "/tmp/pactl").Available,
            "Linux volume never resolves audio tools from PATH or writable custom paths");
        unsafePaths.Done();

        foreach (var identity in new[] { "id 0, type PipeWire:Interface:Node", "id 4294967295, type PipeWire:Interface:Node",
            "id 42, type PipeWire:Interface:Device", "id 42; id, type PipeWire:Interface:Node", new string('x', 4097) })
        {
            var runner = new FakeRunner(check, new Step(Wpctl, ["inspect", WpDefault], Ok(identity)));
            check(!new LinuxSystemVolume(runner, Wpctl, null).Available, "Linux volume requires a concrete valid default node");
            runner.Done();
        }
        foreach (var identity in new[] { "", "--help", "$(id)", "sink; command", "sink\nother", new string('x', 257) })
        {
            var runner = new FakeRunner(check, new Step(Pactl, ["get-default-sink"], Ok(identity)));
            check(!new LinuxSystemVolume(runner, null, Pactl).Available, "Linux volume rejects unsafe or ambiguous default sink names");
            runner.Done();
        }

        foreach (var invalid in new[] { "Volume: NaN", "Volume: Infinity", "Volume: -0.5", "Volume: 0.5; id",
            "Volume: 0.5\nVolume: 0.6", "Volume: 79228162514264337593543950335", new string('x', 4097) })
        {
            var runner = new FakeRunner(check, new Step(Wpctl, ["inspect", WpDefault], Ok("id 42, type PipeWire:Interface:Node\n  media.class = \"Audio/Sink\"")),
                new Step(Wpctl, ["get-volume", WpSink], Ok(invalid)));
            check(!new LinuxSystemVolume(runner, Wpctl, null).Available, "Linux volume malformed WirePlumber read fails closed");
            runner.Done();
        }
        foreach (var invalid in new[] { "", "Volume: mono: -1 / 0% / 0.00 dB", "Volume: mono: 4294967296 / 100% / 0.00 dB",
            "Volume: mono: 65536; id / 100% / 0.00 dB", Pulse(32768, 32768) + "\nextra", new string('x', 4097) })
        {
            var runner = new FakeRunner(check, new Step(Pactl, ["get-default-sink"], Ok(PulseSink + "\n")),
                new Step(Pactl, ["get-sink-volume", PulseSink], Ok(invalid)));
            check(!new LinuxSystemVolume(runner, null, Pactl).Available, "Linux volume malformed PulseAudio read fails closed");
            runner.Done();
        }
        foreach (var result in new[] { Timeout, new LinuxVolumeResult(true, 1, "Volume: 0.50") })
        {
            var runner = new FakeRunner(check, new Step(Wpctl, ["inspect", WpDefault], Ok("id 42, type PipeWire:Interface:Node\n  media.class = \"Audio/Sink\"")),
                new Step(Wpctl, ["get-volume", WpSink], result));
            ExpectFailure(new LinuxSystemVolume(runner, Wpctl, null), "up", "volume_unavailable:", check);
            runner.Done();
        }
        foreach (var result in new[] { Timeout, new LinuxVolumeResult(true, 1, "Mute: no"), Ok("Mute: maybe") })
        {
            var runner = new FakeRunner(check,
                new Step(Pactl, ["get-default-sink"], Ok(PulseSink + "\n")),
                new Step(Pactl, ["get-sink-volume", PulseSink], Ok(Pulse(32768, 32768))),
                new Step(Pactl, ["get-sink-mute", PulseSink], result));
            check(!new LinuxSystemVolume(runner, null, Pactl).Available, "Linux volume requires confirmed mute support");
            runner.Done();
        }
        var injection = new FakeRunner(check);
        var safe = new LinuxSystemVolume(injection, Wpctl, Pactl);
        foreach (var command in new[] { "", "UP", "up; touch /tmp/unsafe", "$(id)", "mute\nup", "--help", "up\0" })
            ExpectFailure(safe, command, "volume_unsupported:", check);
        injection.Done();

        // Inspect process configuration without executing it, including hostile text as one argument.
        var start = LinuxVolumeProcessRunner.StartInfo(Wpctl, ["get-volume", "$(id); echo unsafe"]);
        check(!start.UseShellExecute && start.FileName == Wpctl && start.Arguments.Length == 0
            && start.ArgumentList.SequenceEqual(new[] { "get-volume", "$(id); echo unsafe" }), "Linux volume runner uses argv without a shell");
        check(start.RedirectStandardInput && start.RedirectStandardOutput && start.RedirectStandardError
            && start.Environment["LC_ALL"] == "C", "Linux volume runner bounds redirected output and uses stable locale");
    }

    private static string Pulse(uint left, uint right) =>
        $"Volume: front-left: {left} / {(ulong)left * 100 / 65536}% / {Decibels(left)} dB,   front-right: {right} / {(ulong)right * 100 / 65536}% / {Decibels(right)} dB\n        balance 0.00\n";
    private static string Decibels(uint value) => value == 0 ? "-inf" : value > 65536 ? "+3.00" : "-18.06";

    private static void ExpectFailure(LinuxSystemVolume volume, string command, string prefix, Action<bool, string> check)
    {
        try { volume.Apply(command); throw new Exception("Linux volume unexpectedly accepted " + command); }
        catch (InputInjectionException error) { check(error.Message.StartsWith(prefix, StringComparison.Ordinal), "Linux volume reports " + prefix); }
    }

    private sealed record Step(string Executable, string[] Arguments, LinuxVolumeResult Result);
    private sealed class FakeRunner(Action<bool, string> check, params Step[] steps) : ILinuxVolumeRunner
    {
        private int _next;
        public LinuxVolumeResult Run(string executable, IReadOnlyList<string> arguments, TimeSpan timeout)
        {
            check(_next < steps.Length, "Linux volume does not replay or launch extra commands");
            var step = steps[_next++];
            check(executable == step.Executable && arguments.SequenceEqual(step.Arguments), "Linux volume routes exact default-output arguments");
            check(timeout > TimeSpan.Zero && timeout <= TimeSpan.FromSeconds(1), "Linux volume subprocess has bounded deadline");
            return step.Result;
        }
        internal void Done() => check(_next == steps.Length, "Linux volume consumed exactly the expected commands");
    }
}
