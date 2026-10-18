using System.Runtime.InteropServices;
using System.Runtime.Versioning;

namespace SofaTap;

public sealed class WindowsSystemVolume : ISystemVolume
{
    private readonly EndpointSystemVolume _control;
    public WindowsSystemVolume() : this(OpenDefault) { }
    internal WindowsSystemVolume(Func<ISystemVolumeEndpoint> open) => _control = new(open);
    public bool Available => _control.Available;
    public void Apply(string command) => _control.Apply(command);

    private static ISystemVolumeEndpoint OpenDefault()
    {
        if (!OperatingSystem.IsWindows()) throw new PlatformNotSupportedException();
        return WindowsAudioEndpoint.Open();
    }
}

// MMDevice / IAudioEndpointVolume target the default render endpoint directly,
// without sending multimedia keys into the foreground application.
[SupportedOSPlatform("windows")]
internal sealed class WindowsAudioEndpoint : ISystemVolumeEndpoint
{
    private IEndpointVolume? _volume;
    private WindowsAudioEndpoint(IEndpointVolume volume) => _volume = volume;
    internal static WindowsAudioEndpoint Open()
    {
        object? enumeratorObject = null, endpointObject = null, volumeObject = null;
        try
        {
            var type = Type.GetTypeFromCLSID(new Guid("BCDE0395-E52F-467C-8E3D-C4579291692E"), throwOnError: true)!;
            enumeratorObject = Activator.CreateInstance(type)!;
            // eRender = 0, eMultimedia = 1: the system's default media output,
            // never the communications endpoint or a microphone.
            Marshal.ThrowExceptionForHR(((IDeviceEnumerator)enumeratorObject).GetDefaultAudioEndpoint(0, 1, out var endpoint));
            endpointObject = endpoint;
            var iid = typeof(IEndpointVolume).GUID;
            Marshal.ThrowExceptionForHR(endpoint.Activate(ref iid, 1 /* CLSCTX_INPROC_SERVER */, IntPtr.Zero, out var volume));
            volumeObject = volume;
            var result = new WindowsAudioEndpoint((IEndpointVolume)volume);
            volumeObject = null; // Ownership transfers to the short-lived endpoint.
            return result;
        }
        finally
        {
            if (volumeObject is not null) Marshal.ReleaseComObject(volumeObject);
            if (endpointObject is not null) Marshal.ReleaseComObject(endpointObject);
            if (enumeratorObject is not null) Marshal.ReleaseComObject(enumeratorObject);
        }
    }

    private IEndpointVolume Volume => _volume ?? throw new InvalidOperationException("Endpoint disposed.");
    public float[] ReadLevels()
    {
        Marshal.ThrowExceptionForHR(Volume.GetMasterVolumeLevelScalar(out var level));
        return [level];
    }
    public bool[] ReadMutes()
    {
        Marshal.ThrowExceptionForHR(Volume.GetMute(out var muted));
        return [muted];
    }
    public void SetLevel(int index, float level)
    {
        if (index != 0) throw new InvalidOperationException("Invalid master control.");
        Marshal.ThrowExceptionForHR(Volume.SetMasterVolumeLevelScalar(level, IntPtr.Zero));
    }
    public void SetMute(int index, bool muted)
    {
        if (index != 0) throw new InvalidOperationException("Invalid master control.");
        Marshal.ThrowExceptionForHR(Volume.SetMute(muted, IntPtr.Zero));
    }
    public void Dispose()
    {
        if (_volume is not null) Marshal.ReleaseComObject(_volume);
        _volume = null;
    }

    // PreserveSig retains native HRESULTs. The declaration order follows the
    // Windows SDK vtables; unused preceding entries still occupy their slots.
    [ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IDeviceEnumerator
    {
        [PreserveSig] int EnumAudioEndpoints(int flow, uint mask, out IntPtr devices);
        [PreserveSig] int GetDefaultAudioEndpoint(int flow, int role, out IDevice device);
    }
    [ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IDevice
    {
        [PreserveSig] int Activate(ref Guid iid, uint context, IntPtr parameters, [MarshalAs(UnmanagedType.IUnknown)] out object instance);
    }
    [ComImport, Guid("5CDF2C82-841E-4546-9722-0CF74078229A"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IEndpointVolume
    {
        [PreserveSig] int RegisterControlChangeNotify(IntPtr callback);
        [PreserveSig] int UnregisterControlChangeNotify(IntPtr callback);
        [PreserveSig] int GetChannelCount(out uint count);
        [PreserveSig] int SetMasterVolumeLevel(float level, IntPtr context);
        [PreserveSig] int SetMasterVolumeLevelScalar(float level, IntPtr context);
        [PreserveSig] int GetMasterVolumeLevel(out float level);
        [PreserveSig] int GetMasterVolumeLevelScalar(out float level);
        [PreserveSig] int SetChannelVolumeLevel(uint channel, float level, IntPtr context);
        [PreserveSig] int SetChannelVolumeLevelScalar(uint channel, float level, IntPtr context);
        [PreserveSig] int GetChannelVolumeLevel(uint channel, out float level);
        [PreserveSig] int GetChannelVolumeLevelScalar(uint channel, out float level);
        [PreserveSig] int SetMute([MarshalAs(UnmanagedType.Bool)] bool muted, IntPtr context);
        [PreserveSig] int GetMute([MarshalAs(UnmanagedType.Bool)] out bool muted);
    }
}
