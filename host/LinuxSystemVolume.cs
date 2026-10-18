using System.Diagnostics;
using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;

namespace SofaTap;

// The only subprocesses are fixed, system-installed audio tools. Probes never change audio.
public sealed class LinuxSystemVolume : ISystemVolume
{
    private const string WirePlumberDefaultSink = "@DEFAULT_AUDIO_SINK@";
    private const int PulseNormalVolume = 65536;
    internal static readonly TimeSpan ProcessTimeout = TimeSpan.FromSeconds(1);
    private readonly object _gate = new();
    private readonly ILinuxVolumeRunner _runner;
    private readonly string? _wpctl, _pactl;

    public LinuxSystemVolume() : this(new LinuxVolumeProcessRunner(), Resolve("wpctl"), Resolve("pactl")) { }

    internal LinuxSystemVolume(ILinuxVolumeRunner runner, string? wpctl, string? pactl)
    {
        _runner = runner;
        _wpctl = TrustedPath("wpctl", wpctl) ? wpctl : null;
        _pactl = TrustedPath("pactl", pactl) ? pactl : null;
    }

    public bool Available { get { lock (_gate) return TryRead(out _, out _, out _); } }

    public void Apply(string command)
    {
        // Validate before even probing: caller-controlled strings never enter argv.
        SystemVolume.ValidateCommand(command);
        lock (_gate)
        {
            if (!TryRead(out var executable, out var sink, out var levels))
                throw new InputInjectionException("volume_unavailable: Linux default audio output is unavailable. Install wpctl or pactl and check the audio session.");
            var wirePlumber = executable == _wpctl;
            string[] arguments;
            if (command == "mute")
                arguments = [wirePlumber ? "set-mute" : "set-sink-mute", sink!, "toggle"];
            else
            {
                var delta = command == "up" ? .05m : -.05m;
                // Absolute values make the ceiling apply even when an existing level exceeds 100%.
                // PulseAudio's channel list preserves separate channel levels instead of flattening them.
                var values = levels!.Select(level => Math.Clamp(level + delta, 0m, 1m));
                arguments = wirePlumber
                    ? ["set-volume", sink!, values.Single().ToString("0.#####", CultureInfo.InvariantCulture)]
                    : ["set-sink-volume", sink!, .. values.Select(value =>
                        decimal.Round(value * PulseNormalVolume, 0, MidpointRounding.AwayFromZero).ToString(CultureInfo.InvariantCulture))];
            }
            // A process can fail after applying a change. Never retry or switch backends after this point.
            if (!Run(executable!, arguments).Succeeded)
                throw new InputInjectionException("volume_unknown: Linux did not confirm the volume change. Check the output volume before trying again.");
        }
    }

    private bool TryRead(out string? executable, out string? sink, out decimal[]? levels)
    {
        executable = null; sink = null; levels = null;
        if (_wpctl is not null)
        {
            var identity = Run(_wpctl, ["inspect", WirePlumberDefaultSink]);
            var id = identity.Succeeded ? ParseWirePlumberId(identity.Output) : null;
            if (id is not null)
            {
                var volume = Run(_wpctl, ["get-volume", id]);
                if (volume.Succeeded && TryParseWirePlumber(volume.Output, out var value))
                { executable = _wpctl; sink = id; levels = [value]; return true; }
            }
        }
        if (_pactl is not null)
        {
            var identity = Run(_pactl, ["get-default-sink"]);
            var name = identity.Output.Trim();
            // Use a concrete, bounded symbolic name for the entire operation. No shell interpolation.
            if (!identity.Succeeded || name.Length is < 1 or > 256 || !Regex.IsMatch(name,
                @"\A[a-zA-Z0-9_][a-zA-Z0-9_.-]*\z", RegexOptions.CultureInvariant, TimeSpan.FromMilliseconds(50))) return false;
            var volume = Run(_pactl, ["get-sink-volume", name]);
            if (volume.Succeeded && TryParsePulse(volume.Output, out var channels))
            {
                var mute = Run(_pactl, ["get-sink-mute", name]);
                if (mute.Succeeded && mute.Output.Trim() is "Mute: yes" or "Mute: no")
                { executable = _pactl; sink = name; levels = channels; return true; }
            }
        }
        return false;
    }

    private static string? ParseWirePlumberId(string output)
    {
        if (output.Length > LinuxVolumeProcessRunner.OutputLimit) return null;
        var match = Regex.Match(output.Split('\n')[0].Trim(), @"\Aid ([0-9]+), type PipeWire:Interface:Node\z",
            RegexOptions.CultureInvariant, TimeSpan.FromMilliseconds(50));
        return match.Success && uint.TryParse(match.Groups[1].Value, out var id) && id is > 0 and < uint.MaxValue
            ? id.ToString(CultureInfo.InvariantCulture) : null;
    }

    private LinuxVolumeResult Run(string executable, string[] arguments)
    {
        try { return _runner.Run(executable, arguments, ProcessTimeout); }
        catch (Exception error) when (error is IOException or InvalidOperationException or OperationCanceledException
            or System.ComponentModel.Win32Exception or UnauthorizedAccessException)
        { return new(false, -1, ""); }
    }

    private static bool TryParseWirePlumber(string text, out decimal value)
    {
        value = 0;
        if (text.Length > LinuxVolumeProcessRunner.OutputLimit) return false;
        var match = Regex.Match(text.Trim(), @"\AVolume: ([0-9]+(?:\.[0-9]+)?)(?: \[MUTED\])?\z",
            RegexOptions.CultureInvariant, TimeSpan.FromMilliseconds(50));
        return match.Success && decimal.TryParse(match.Groups[1].Value, NumberStyles.AllowDecimalPoint,
            CultureInfo.InvariantCulture, out value) && value <= 65536m;
    }

    private static bool TryParsePulse(string text, out decimal[] values)
    {
        values = [];
        if (text.Length > LinuxVolumeProcessRunner.OutputLimit) return false;
        var lines = text.Trim().Split('\n');
        if (lines.Length is < 1 or > 2 || !lines[0].StartsWith("Volume: ", StringComparison.Ordinal)) return false;
        if (lines.Length == 2 && !Regex.IsMatch(lines[1].Trim(), @"\Abalance -?[0-9]+(?:\.[0-9]+)?\z",
            RegexOptions.CultureInvariant, TimeSpan.FromMilliseconds(50))) return false;
        var channels = lines[0][8..].Split(',');
        if (channels.Length is < 1 or > 32) return false;
        var result = new decimal[channels.Length];
        for (var index = 0; index < channels.Length; index++)
        {
            var match = Regex.Match(channels[index].Trim(),
                @"\A[a-z0-9-]+:\s+([0-9]+)\s*/\s*[0-9]+%\s*/\s*(?:-inf|[+-]?[0-9]+(?:\.[0-9]+)?) dB\z",
                RegexOptions.CultureInvariant, TimeSpan.FromMilliseconds(50));
            if (!match.Success || !uint.TryParse(match.Groups[1].Value, NumberStyles.None, CultureInfo.InvariantCulture, out var raw)) return false;
            result[index] = (decimal)raw / PulseNormalVolume;
        }
        values = result;
        return true;
    }

    private static bool TrustedPath(string tool, string? path) => path == "/usr/bin/" + tool || path == "/bin/" + tool;
    private static string? Resolve(string tool) => !OperatingSystem.IsLinux() ? null
        : new[] { "/usr/bin/" + tool, "/bin/" + tool }.FirstOrDefault(File.Exists);
}

internal interface ILinuxVolumeRunner
{
    LinuxVolumeResult Run(string executable, IReadOnlyList<string> arguments, TimeSpan timeout);
}

internal sealed record LinuxVolumeResult(bool Completed, int ExitCode, string Output)
{
    internal bool Succeeded => Completed && ExitCode == 0;
}

internal sealed class LinuxVolumeProcessRunner : ILinuxVolumeRunner
{
    internal const int OutputLimit = 4096;

    internal static ProcessStartInfo StartInfo(string executable, IReadOnlyList<string> arguments)
    {
        var start = new ProcessStartInfo(executable)
        {
            UseShellExecute = false, CreateNoWindow = true,
            RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true,
            StandardOutputEncoding = new UTF8Encoding(false, true), StandardErrorEncoding = new UTF8Encoding(false, true)
        };
        foreach (var argument in arguments) start.ArgumentList.Add(argument);
        // Parse stable English output without overriding the user's audio server/session environment.
        start.Environment["LC_ALL"] = "C";
        start.Environment["LANG"] = "C";
        return start;
    }

    public LinuxVolumeResult Run(string executable, IReadOnlyList<string> arguments, TimeSpan timeout)
    {
        using var process = new Process { StartInfo = StartInfo(executable, arguments) };
        using var deadline = new CancellationTokenSource(timeout);
        try
        {
            if (!process.Start()) return new(false, -1, "");
            process.StandardInput.Close();
            var output = ReadBounded(process.StandardOutput, deadline.Token);
            var diagnostics = ReadBounded(process.StandardError, deadline.Token);
            Task.WhenAll(output, diagnostics, process.WaitForExitAsync(deadline.Token))
                .WaitAsync(deadline.Token).GetAwaiter().GetResult();
            return new(true, process.ExitCode, output.GetAwaiter().GetResult());
        }
        catch (Exception error) when (error is IOException or InvalidOperationException or OperationCanceledException
            or System.ComponentModel.Win32Exception or UnauthorizedAccessException or DecoderFallbackException)
        { return new(false, -1, ""); }
        finally
        {
            try
            {
                if (!process.HasExited) { process.Kill(entireProcessTree: true); process.WaitForExit(250); }
            }
            catch (Exception error) when (error is InvalidOperationException or System.ComponentModel.Win32Exception or NotSupportedException) { }
        }
    }

    private static async Task<string> ReadBounded(StreamReader reader, CancellationToken cancellation)
    {
        var result = new StringBuilder();
        var buffer = new char[256];
        int count;
        while ((count = await reader.ReadAsync(buffer.AsMemory(), cancellation)) != 0)
        {
            if (result.Length + count > OutputLimit) throw new IOException("Audio tool output exceeded its limit.");
            result.Append(buffer, 0, count);
        }
        return result.ToString();
    }
}
