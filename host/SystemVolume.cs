using System.Runtime.InteropServices;
using System.Numerics;

namespace SofaTap;

/// <summary>Default output only. Availability probes must never change audio or request access.</summary>
public interface ISystemVolume
{
    bool Available { get; }
    void Apply(string command);
}

internal static class SystemVolume
{
    internal static ISystemVolume? Create(bool dryRun) => dryRun ? null
        : OperatingSystem.IsWindows() ? new WindowsSystemVolume()
        : OperatingSystem.IsMacOS() ? new MacSystemVolume()
        : OperatingSystem.IsLinux() ? new LinuxSystemVolume() : null;

    internal static void ValidateCommand(string command)
    {
        if (command is not ("up" or "down" or "mute"))
            throw new InputInjectionException("volume_unsupported: Unsupported volume command.");
    }

    internal static T[] AdjustLevels<T>(T[] levels, bool increase) where T : struct, IFloatingPoint<T>
    {
        var peak = levels.Max();
        var step = T.CreateChecked(.05m);
        var targetPeak = T.Clamp(peak + (increase ? step : -step), T.Zero, T.One);
        if (targetPeak == peak) return [.. levels];
        // Match virtual main-volume semantics: preserve relative channel balance,
        // including deliberately silent channels, when changing the common level.
        // All-zero output has no recoverable ratio; increasing starts all channels
        // at 5%, while decreasing zero remains a no-op.
        return levels.Select(level => peak == T.Zero ? targetPeak
            : T.Clamp(level / peak * targetPeak, T.Zero, T.One)).ToArray();
    }
}

// A freshly opened endpoint pins one output device for the whole operation. Native
// wrappers expose master controls or, where needed, every writable output channel.
internal interface ISystemVolumeEndpoint : IDisposable
{
    float[] ReadLevels();
    bool[] ReadMutes();
    void SetLevel(int index, float level);
    void SetMute(int index, bool muted);
}

internal sealed class EndpointSystemVolume(Func<ISystemVolumeEndpoint> open) : ISystemVolume
{
    private readonly object _gate = new();
    public bool Available
    {
        get
        {
            lock (_gate)
            {
                try
                {
                    using var endpoint = open();
                    ValidateLevels(endpoint.ReadLevels());
                    ValidateMutes(endpoint.ReadMutes());
                    return true;
                }
                catch (Exception error) when (IsAudioFailure(error)) { return false; }
            }
        }
    }

    public void Apply(string command)
    {
        SystemVolume.ValidateCommand(command);
        lock (_gate)
        {
            var writeAttempted = false;
            try
            {
                using var endpoint = open();
                // Validate both advertised operations before attempting any write.
                var levels = endpoint.ReadLevels(); ValidateLevels(levels);
                var mutes = endpoint.ReadMutes(); ValidateMutes(mutes);
                if (command == "mute")
                {
                    var target = !mutes.All(muted => muted);
                    for (var index = 0; index < mutes.Length; index++)
                    {
                        if (mutes[index] == target) continue;
                        writeAttempted = true;
                        endpoint.SetMute(index, target);
                    }
                }
                else
                {
                    var targets = SystemVolume.AdjustLevels(levels, command == "up");
                    for (var index = 0; index < levels.Length; index++)
                    {
                        var target = targets[index];
                        if (target == levels[index]) continue;
                        writeAttempted = true;
                        endpoint.SetLevel(index, target);
                    }
                }
            }
            catch (Exception error) when (IsAudioFailure(error))
            {
                // Native writes can partially succeed. Never retry, fall back to keys,
                // roll back, or leak raw device/driver diagnostics to the controller.
                throw new InputInjectionException(writeAttempted
                    ? "volume_unknown: The output did not confirm the volume change. Check the computer before trying again."
                    : "volume_unavailable: The default output does not provide writable volume and mute controls.");
            }
        }
    }

    private static bool IsAudioFailure(Exception error) => error is IOException or InvalidOperationException
        or ExternalException or UnauthorizedAccessException or NotSupportedException or DllNotFoundException or EntryPointNotFoundException;
    private static void ValidateLevels(float[] levels)
    {
        if (levels.Length is < 1 or > 64 || levels.Any(value => !float.IsFinite(value) || value is < 0 or > 1))
            throw new IOException("Invalid audio scalar.");
    }
    private static void ValidateMutes(bool[] mutes)
    {
        if (mutes.Length is < 1 or > 64) throw new IOException("Missing mute controls.");
    }
}
