using System.Runtime.InteropServices;

namespace SofaTap;

public sealed class MacSystemVolume : ISystemVolume
{
    private readonly EndpointSystemVolume _control;
    public MacSystemVolume() : this(new MacAudioApi()) { }
    internal MacSystemVolume(IMacAudioApi api) => _control = new(() => new MacAudioEndpoint(api));
    public bool Available => _control.Available;
    public void Apply(string command) => _control.Apply(command);
}

// Native property access stays behind a recording adapter in tests. No AX,
// AppleScript, media-key synthesis or foreground-app interaction is involved.
internal interface IMacAudioApi
{
    uint DefaultOutputDevice();
    int OutputChannelCount(uint device);
    bool Writable(uint device, uint selector, uint element);
    float ReadLevel(uint device, uint element);
    bool ReadMute(uint device, uint element);
    void WriteLevel(uint device, uint element, float level);
    void WriteMute(uint device, uint element, bool muted);
}

internal sealed class MacAudioEndpoint : ISystemVolumeEndpoint
{
    internal const uint Volume = 0x766f6c6d; // 'volm'
    internal const uint Mute = 0x6d757465; // 'mute'
    private readonly IMacAudioApi _api;
    private readonly uint _device;
    private readonly uint[] _levels, _mutes;
    internal MacAudioEndpoint(IMacAudioApi api)
    {
        _api = api;
        _device = api.DefaultOutputDevice();
        if (_device == 0) throw new IOException("No default output.");
        _levels = Elements(Volume);
        _mutes = Elements(Mute);
    }
    private uint[] Elements(uint selector)
    {
        if (_api.Writable(_device, selector, 0)) return [0];
        var count = _api.OutputChannelCount(_device);
        if (count is < 1 or > 64) throw new IOException("Invalid output channels.");
        var channels = Enumerable.Range(1, count).Select(value => (uint)value).ToArray();
        // Requiring every channel avoids silently changing only one speaker or
        // advertising mute for a digital output which has no software controls.
        if (channels.Any(channel => !_api.Writable(_device, selector, channel)))
            throw new IOException("Output has no complete writable controls.");
        return channels;
    }
    public float[] ReadLevels() => _levels.Select(element => _api.ReadLevel(_device, element)).ToArray();
    public bool[] ReadMutes() => _mutes.Select(element => _api.ReadMute(_device, element)).ToArray();
    public void SetLevel(int index, float level) => _api.WriteLevel(_device, _levels[index], level);
    public void SetMute(int index, bool muted) => _api.WriteMute(_device, _mutes[index], muted);
    public void Dispose() { }
}

internal sealed class MacAudioApi : IMacAudioApi
{
    private const uint Global = 0x676c6f62, Output = 0x6f757470;
    public uint DefaultOutputDevice()
    {
        if (!OperatingSystem.IsMacOS()) throw new PlatformNotSupportedException();
        return ReadUInt(1 /* kAudioObjectSystemObject */, new(0x644f7574 /* 'dOut' */, Global, 0));
    }
    public bool Writable(uint device, uint selector, uint element)
    {
        var address = new Address(selector, Output, element);
        return Native.AudioObjectHasProperty(device, ref address) != 0 &&
            Native.AudioObjectIsPropertySettable(device, ref address, out var writable) == 0 && writable != 0;
    }
    public float ReadLevel(uint device, uint element) => BitConverter.UInt32BitsToSingle(
        ReadUInt(device, new(MacAudioEndpoint.Volume, Output, element)));
    public bool ReadMute(uint device, uint element)
    {
        var muted = ReadUInt(device, new(MacAudioEndpoint.Mute, Output, element));
        if (muted > 1) throw new IOException("Invalid mute value.");
        return muted == 1;
    }
    public void WriteLevel(uint device, uint element, float level) => WriteUInt(device,
        new(MacAudioEndpoint.Volume, Output, element), BitConverter.SingleToUInt32Bits(level));
    public void WriteMute(uint device, uint element, bool muted) => WriteUInt(device,
        new(MacAudioEndpoint.Mute, Output, element), muted ? 1u : 0u);

    public int OutputChannelCount(uint device)
    {
        var address = new Address(0x736c6179 /* 'slay' */, Output, 0);
        Check(Native.AudioObjectGetPropertyDataSize(device, ref address, 0, IntPtr.Zero, out var size));
        if (size is < 8 or > 65536) throw new IOException("Invalid stream configuration.");
        var buffer = Marshal.AllocHGlobal(checked((int)size));
        try
        {
            var capacity = size;
            Check(Native.AudioObjectGetPropertyData(device, ref address, 0, IntPtr.Zero, ref size, buffer));
            if (size > capacity) throw new IOException("Stream configuration grew.");
            var bytes = new byte[size];
            Marshal.Copy(buffer, bytes, 0, bytes.Length);
            return ChannelCount(bytes, IntPtr.Size);
        }
        finally { Marshal.FreeHGlobal(buffer); }
    }
    internal static int ChannelCount(byte[] bytes, int pointerSize)
    {
        // AudioBufferList aligns its first AudioBuffer to the pointer width;
        // AudioBuffer is two UInt32 fields followed by a data pointer.
        if (pointerSize is not (4 or 8) || bytes.Length < pointerSize) throw new IOException("Invalid buffer list.");
        var count = BitConverter.ToUInt32(bytes, 0);
        var stride = 8 + pointerSize;
        if (count > 64 || pointerSize + (long)count * stride > bytes.Length) throw new IOException("Invalid buffer list.");
        var channels = 0;
        for (var index = 0; index < count; index++)
        {
            var number = BitConverter.ToUInt32(bytes, pointerSize + index * stride);
            if (number > 64 || channels + number > 64) throw new IOException("Too many output channels.");
            channels += (int)number;
        }
        return channels;
    }
    private static uint ReadUInt(uint device, Address address)
    {
        uint size = 4;
        Check(Native.ReadUInt(device, ref address, 0, IntPtr.Zero, ref size, out var value));
        if (size != 4) throw new IOException("Invalid audio property size.");
        return value;
    }
    private static void WriteUInt(uint device, Address address, uint value) =>
        Check(Native.WriteUInt(device, ref address, 0, IntPtr.Zero, 4, ref value));
    private static void Check(int status)
    {
        if (status != 0) throw new IOException("CoreAudio property unavailable.");
    }
    [StructLayout(LayoutKind.Sequential)]
    internal struct Address(uint selector, uint scope, uint element)
    {
        internal uint Selector = selector, Scope = scope, Element = element;
    }
    private static class Native
    {
        private const string Library = "/System/Library/Frameworks/CoreAudio.framework/CoreAudio";
        [DllImport(Library)] internal static extern byte AudioObjectHasProperty(uint device, ref Address address);
        [DllImport(Library)] internal static extern int AudioObjectIsPropertySettable(uint device, ref Address address, out byte writable);
        [DllImport(Library)] internal static extern int AudioObjectGetPropertyDataSize(uint device, ref Address address, uint qualifierSize, IntPtr qualifier, out uint size);
        [DllImport(Library)] internal static extern int AudioObjectGetPropertyData(uint device, ref Address address, uint qualifierSize, IntPtr qualifier, ref uint size, IntPtr value);
        [DllImport(Library, EntryPoint = "AudioObjectGetPropertyData")] internal static extern int ReadUInt(uint device, ref Address address, uint qualifierSize, IntPtr qualifier, ref uint size, out uint value);
        [DllImport(Library, EntryPoint = "AudioObjectSetPropertyData")] internal static extern int WriteUInt(uint device, ref Address address, uint qualifierSize, IntPtr qualifier, uint size, ref uint value);
    }
}
