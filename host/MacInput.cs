using System.Diagnostics;
using System.Runtime.InteropServices;

namespace SofaTap;

/// <summary>
/// Submits events to Quartz, which provides no target-application delivery acknowledgement.
/// A successful Apply means submission completed, not that a field consumed or saved its text.
/// </summary>
public sealed class MacInput : IInputInjector, IDisposable
{
    private readonly IMacEventSink _sink;
    private volatile bool _disposed;
    private readonly object _gate = new();
    private readonly HashSet<uint> _buttons = [];
    private readonly Dictionary<ushort, MacEvent> _keys = [];
    private double _fractionX, _fractionY, _scrollX, _scrollY;
    private int _attempted;
    private uint? _lastClickButton;
    private MacPoint _lastClickPosition;
    private double _lastClickTime;
    private long _clickCount;

    public MacInput() : this(new QuartzEventSink()) { }
    internal MacInput(IMacEventSink sink) => _sink = sink;

    // Neither this property nor Available requests permission or opens system UI.
    public string StatusCode
    {
        get
        {
            try { return _disposed ? "desktop_unavailable" : _sink.StatusCode; }
            catch (Exception error) when (error is DllNotFoundException or EntryPointNotFoundException or InvalidOperationException)
            { return "desktop_unavailable"; }
        }
    }
    public bool Available => StatusCode == "ready";

    /// <summary>Only call in response to an explicit local user action. Never from startup or a status check.</summary>
    public static void RequestAccess()
    {
        if (OperatingSystem.IsMacOS()) QuartzNative.CGRequestPostEventAccess();
    }

    public void Apply(ActionMessage action)
    {
        lock (_gate)
        {
            if (!Available) { ReleaseOwned(); throw Unavailable(); }
            _attempted = 0;
            try
            {
                switch (action.Type)
                {
                    case "move":
                        CheckMouseOwnership();
                        _fractionX += action.Dx; _fractionY += action.Dy;
                        var dx = (int)_fractionX; var dy = (int)_fractionY;
                        if (dx != 0 || dy != 0)
                        {
                            var current = _sink.CursorPosition;
                            var target = ClampToDisplays(new(current.X + dx, current.Y + dy), _sink.Displays);
                            if (!WithinClickDistance(target)) ResetClicks();
                            var button = _buttons.Contains(0) ? 0u : _buttons.Contains(1) ? 1u : 0u;
                            var type = _buttons.Contains(0) ? 6u : _buttons.Contains(1) ? 7u : 5u;
                            Submit(new(MacEventKind.Mouse, MouseType: type, Button: button, Position: target,
                                DeltaX: (int)(target.X - current.X), DeltaY: (int)(target.Y - current.Y), ClickCount: type == 5 ? 0 : 1));
                        }
                        _fractionX -= dx; _fractionY -= dy;
                        break;
                    case "scroll":
                        ResetClicks();
                        _scrollX += action.Dx; _scrollY += action.Dy;
                        var sx = (int)_scrollX; var sy = (int)_scrollY;
                        if (sx != 0 || sy != 0) Submit(new(MacEventKind.Scroll, DeltaX: sx, DeltaY: sy));
                        _scrollX -= sx; _scrollY -= sy;
                        break;
                    case "click":
                        if (_buttons.Count > 0)
                            throw new InputInjectionException("input_busy: Release the remote drag button before clicking.");
                        CheckMouseOwnership();
                        var clickButton = ButtonCode(action.Button!);
                        var position = _sink.CursorPosition;
                        var now = _sink.MonotonicSeconds;
                        var count = _lastClickButton == clickButton && now >= _lastClickTime
                            && now - _lastClickTime <= _sink.DoubleClickInterval && WithinClickDistance(position)
                            ? _clickCount + 1 : 1;
                        Submit(MouseButton(clickButton, true, position, count));
                        Submit(MouseButton(clickButton, false, position, count));
                        _lastClickButton = clickButton; _lastClickPosition = position; _lastClickTime = now; _clickCount = count;
                        break;
                    case "button":
                        ResetClicks();
                        if (action.Down) CheckMouseOwnership();
                        var heldButton = ButtonCode(action.Button!);
                        if (action.Down != _buttons.Contains(heldButton))
                            Submit(MouseButton(heldButton, action.Down, _sink.CursorPosition));
                        break;
                    case "key":
                        ResetClicks();
                        CheckKeyboardOwnership(KeyCode(action.Key!));
                        foreach (var item in ShortcutEvents(action.Key!, action.Modifiers!)) Submit(item);
                        break;
                    case "text":
                        ResetClicks();
                        CheckKeyboardOwnership(0);
                        foreach (var item in TextEvents(action.Text!)) Submit(item);
                        break;
                    default:
                        throw new InputInjectionException("unsupported_key: Unsupported macOS input action.");
                }
            }
            catch (Exception error) when (error is InputInjectionException or InvalidOperationException or ExternalException
                or DllNotFoundException or EntryPointNotFoundException)
            {
                // A rejected click during a drag must not secretly release that drag while the
                // phone still believes the button is held. No events have been attempted yet.
                if (_attempted == 0 && error is InputInjectionException && error.Message.StartsWith("input_busy:", StringComparison.Ordinal))
                { ResetClicks(); throw; }
                ReleaseOwned();
                if (_attempted > 0)
                    throw new InputInjectionException("input_partial: macOS event submission stopped. Some input may have been delivered; check the screen before retrying.");
                if (error is InputInjectionException) throw;
                throw new InputInjectionException("input_failed: macOS could not prepare input events. Check the desktop and Accessibility permission.");
            }
        }
    }

    public void Dispose()
    {
        lock (_gate)
        {
            if (_disposed) return;
            ReleaseOwned();
            _disposed = true;
            (_sink as IDisposable)?.Dispose();
        }
    }

    public void ReleaseAll()
    {
        lock (_gate) { ReleaseOwned(); }
    }

    private static InputInjectionException Unavailable() => new(
        "input_unavailable: Sign in and unlock the Mac, then allow Sofatap in Privacy & Security > Accessibility.");

    private void CheckKeyboardOwnership(ushort key)
    {
        // Include right-hand modifier keys and Fn. Never release a physical key that we do not own.
        ushort[] modifiers = [54, 55, 56, 58, 59, 60, 61, 62, 63];
        if (_sink.KeyIsDown(key) || modifiers.Any(_sink.KeyIsDown))
            throw new InputInjectionException("input_busy: Release the physical keyboard keys before sending text or a shortcut.");
    }
    private void CheckMouseOwnership()
    {
        if (Enumerable.Range(0, 2).Any(button => !_buttons.Contains((uint)button) && _sink.ButtonIsDown((uint)button)))
            throw new InputInjectionException("input_busy: Release the physical mouse buttons before using the remote pointer.");
    }
    private void Submit(MacEvent item)
    {
        if (!Available) throw Unavailable();
        // Once Post is attempted its outcome can be unknown. Remember downs before calling it,
        // and forget ups only after it returns, so an interrupted submission can always release them.
        if (item.Kind == MacEventKind.Key && item.Down) _keys[item.KeyCode] = item;
        if (item.Kind == MacEventKind.Mouse && item.MouseType is 1 or 3) _buttons.Add(item.Button);
        _attempted++;
        _sink.Post(item);
        if (item.Kind == MacEventKind.Key && !item.Down) _keys.Remove(item.KeyCode);
        if (item.Kind == MacEventKind.Mouse && item.MouseType is 2 or 4) _buttons.Remove(item.Button);
    }
    private void ReleaseOwned()
    {
        try
        {
            if (Available)
            {
                var flags = _keys.Keys.Aggregate(0UL, (current, key) => current | ModifierFlag(key));
                foreach (var key in _keys.Values.Reverse())
                {
                    flags &= ~ModifierFlag(key.KeyCode);
                    TryRelease(key with { Down = false, Flags = flags });
                }
                if (_buttons.Count > 0)
                {
                    var position = _sink.CursorPosition;
                    foreach (var button in _buttons) TryRelease(MouseButton(button, false, position));
                }
            }
        }
        catch (Exception error) when (error is InputInjectionException or InvalidOperationException or ExternalException
            or DllNotFoundException or EntryPointNotFoundException) { }
        finally
        {
            // Never replay releases into a different user's session after a lock or logout.
            _keys.Clear(); _buttons.Clear();
            _fractionX = 0; _fractionY = 0; _scrollX = 0; _scrollY = 0;
            ResetClicks();
        }
    }
    private void TryRelease(MacEvent item)
    {
        try { if (Available) _sink.Post(item); }
        catch (Exception error) when (error is InputInjectionException or InvalidOperationException or ExternalException
            or DllNotFoundException or EntryPointNotFoundException) { }
    }

    private static uint ButtonCode(string button) => button switch
    { "left" => 0, "right" => 1, _ => throw new InputInjectionException("unsupported_key: Unsupported mouse button.") };
    private static MacEvent MouseButton(uint button, bool down, MacPoint position, long count = 1) => new(MacEventKind.Mouse,
        MouseType: button == 0 ? down ? 1u : 2u : down ? 3u : 4u, Button: button, Position: position, ClickCount: count);
    private bool WithinClickDistance(MacPoint position) => _lastClickButton != null
        && Math.Pow(position.X - _lastClickPosition.X, 2) + Math.Pow(position.Y - _lastClickPosition.Y, 2)
            <= Math.Pow(_sink.DoubleClickDistance, 2);
    private void ResetClicks() { _lastClickButton = null; _clickCount = 0; }

    // Virtual codes come from the SDK's HIToolbox/Events.h. ctrl is Control; win is Command.
    internal static ushort KeyCode(string key) => key switch
    {
        "a" => 0x00, "z" => 0x06, "x" => 0x07, "c" => 0x08, "v" => 0x09,
        "enter" => 0x24, "tab" => 0x30, "space" => 0x31, "backspace" => 0x33, "escape" => 0x35,
        "win" => 0x37, "shift" => 0x38, "alt" => 0x3A, "ctrl" => 0x3B,
        "home" => 0x73, "pageup" => 0x74, "delete" => 0x75, "end" => 0x77, "pagedown" => 0x79,
        "left" => 0x7B, "right" => 0x7C, "down" => 0x7D, "up" => 0x7E,
        _ => throw new InputInjectionException("unsupported_key: Unsupported macOS key.")
    };
    private static ulong ModifierFlag(ushort key) => key switch
    { 0x38 => 0x00020000, 0x3B => 0x00040000, 0x3A => 0x00080000, 0x37 => 0x00100000, _ => 0 };
    internal static IEnumerable<MacEvent> ShortcutEvents(string key, string[] modifiers)
    {
        var flags = 0UL;
        foreach (var modifier in modifiers)
        {
            var code = KeyCode(modifier); flags |= ModifierFlag(code);
            yield return new(MacEventKind.Key, KeyCode: code, Down: true, Flags: flags);
        }
        yield return new(MacEventKind.Key, KeyCode: KeyCode(key), Down: true, Flags: flags);
        yield return new(MacEventKind.Key, KeyCode: KeyCode(key), Down: false, Flags: flags);
        foreach (var modifier in modifiers.Reverse())
        {
            var code = KeyCode(modifier); flags &= ~ModifierFlag(code);
            yield return new(MacEventKind.Key, KeyCode: code, Down: false, Flags: flags);
        }
    }
    internal static IEnumerable<MacEvent> TextEvents(string text)
    {
        // Bound each Quartz Unicode payload, preserving surrogate pairs. Explicit line breaks
        // become Return events; nothing is appended after the user's text.
        var normalized = text.Replace("\r\n", "\n", StringComparison.Ordinal).Replace('\r', '\n');
        for (var index = 0; index < normalized.Length;)
        {
            var start = index;
            ushort keyCode = 0;
            string chunk;
            if (normalized[index] == '\n') { chunk = "\r"; keyCode = 0x24; index++; }
            else
            {
                while (index < normalized.Length && normalized[index] != '\n' && index - start < 20)
                {
                    var units = char.IsHighSurrogate(normalized[index]) ? 2 : 1;
                    if (units == 2 && (index + 1 >= normalized.Length || !char.IsLowSurrogate(normalized[index + 1]))
                        || char.IsLowSurrogate(normalized[index]) || normalized[index] == '\0')
                        throw new InputInjectionException("invalid_message: Invalid Unicode text.");
                    if (index - start + units > 20) break;
                    index += units;
                }
                chunk = normalized[start..index];
            }
            yield return new(MacEventKind.Key, KeyCode: keyCode, Down: true, Unicode: chunk);
            yield return new(MacEventKind.Key, KeyCode: keyCode, Down: false, Unicode: chunk);
        }
    }
    internal static MacPoint ClampToDisplays(MacPoint point, IReadOnlyList<MacRect> displays)
    {
        if (displays.Count == 0) throw new InvalidOperationException("No active displays.");
        // Work in Quartz global coordinates, preserving displays left of or above the main one.
        var best = point; var distance = double.PositiveInfinity;
        foreach (var display in displays)
        {
            if (display.Width <= 0 || display.Height <= 0) continue;
            var candidate = new MacPoint(Math.Clamp(point.X, display.X, display.X + display.Width - 1),
                Math.Clamp(point.Y, display.Y, display.Y + display.Height - 1));
            var delta = Math.Pow(point.X - candidate.X, 2) + Math.Pow(point.Y - candidate.Y, 2);
            if (delta < distance) { distance = delta; best = candidate; }
        }
        if (double.IsPositiveInfinity(distance)) throw new InvalidOperationException("No usable displays.");
        return best;
    }
}

internal enum MacEventKind { Mouse, Key, Scroll }
internal readonly record struct MacPoint(double X, double Y);
internal readonly record struct MacRect(double X, double Y, double Width, double Height);
internal sealed record MacEvent(MacEventKind Kind, uint MouseType = 0, uint Button = 0, MacPoint Position = default,
    int DeltaX = 0, int DeltaY = 0, ushort KeyCode = 0, bool Down = false, ulong Flags = 0, string? Unicode = null, long ClickCount = 0);
internal interface IMacEventSink
{
    string StatusCode { get; }
    MacPoint CursorPosition { get; }
    IReadOnlyList<MacRect> Displays { get; }
    double MonotonicSeconds { get; }
    double DoubleClickInterval { get; }
    double DoubleClickDistance { get; }
    bool KeyIsDown(ushort key);
    bool ButtonIsDown(uint button);
    void Post(MacEvent item);
}

internal sealed class QuartzEventSink : IMacEventSink, IDisposable
{
    private readonly CachedMacPostPermission _postPermission = new(QuartzNative.CGPreflightPostEventAccess);
    public void Dispose() => _postPermission.Dispose();
    public string StatusCode
    {
        get
        {
            if (!OperatingSystem.IsMacOS() || !HasConsoleSession()) return "desktop_unavailable";
            return
#if !SOFATAP_MAC_APP_STORE
                QuartzNative.AXIsProcessTrusted() &&
#endif
                _postPermission.IsAllowed
                ? "ready" : "accessibility_required";
        }
    }
    private static bool HasConsoleSession()
    {
        var session = QuartzNative.CGSessionCopyCurrentDictionary();
        if (session == IntPtr.Zero) return false;
        try
        {
            if (ReadBoolean(session, "kCGSSessionOnConsoleKey") != true
                || ReadBoolean(session, "kCGSessionLoginDoneKey") != true) return false;
            var user = ReadValue(session, "kCGSSessionUserIDKey");
            if (user == IntPtr.Zero || QuartzNative.CFGetTypeID(user) != QuartzNative.CFNumberGetTypeID()
                || !QuartzNative.CFNumberGetValue(user, 3, out var uid) || uid != QuartzNative.geteuid()) return false;
            // This optional WindowServer state is present when locked and normally absent when
            // unlocked. An unrecognized value is denied. No private CGS function is invoked.
            var locked = ReadValue(session, "CGSSessionScreenIsLocked");
            return locked == IntPtr.Zero || ReadBoolean(session, "CGSSessionScreenIsLocked") == false;
        }
        finally { QuartzNative.CFRelease(session); }
    }
    private static IntPtr ReadValue(IntPtr dictionary, string name)
    {
        var key = QuartzNative.CFStringCreateWithCString(IntPtr.Zero, name, 0x08000100);
        if (key == IntPtr.Zero) throw new InvalidOperationException("Could not read session state.");
        try { return QuartzNative.CFDictionaryGetValue(dictionary, key); }
        finally { QuartzNative.CFRelease(key); }
    }
    private static bool? ReadBoolean(IntPtr dictionary, string name)
    {
        var value = ReadValue(dictionary, name);
        return value != IntPtr.Zero && QuartzNative.CFGetTypeID(value) == QuartzNative.CFBooleanGetTypeID()
            ? QuartzNative.CFBooleanGetValue(value) : null;
    }
    public MacPoint CursorPosition
    {
        get
        {
            var item = QuartzNative.CGEventCreate(IntPtr.Zero);
            if (item == IntPtr.Zero) throw new InvalidOperationException("Could not locate pointer.");
            try { var point = QuartzNative.CGEventGetLocation(item); return new(point.X, point.Y); }
            finally { QuartzNative.CFRelease(item); }
        }
    }
    public IReadOnlyList<MacRect> Displays
    {
        get
        {
            var ids = new uint[64];
            if (QuartzNative.CGGetActiveDisplayList((uint)ids.Length, ids, out var count) != 0 || count == 0 || count > ids.Length)
                throw new InvalidOperationException("Could not read active displays.");
            return ids.Take((int)count).Select(id =>
            {
                var rect = QuartzNative.CGDisplayBounds(id);
                return new MacRect(rect.Origin.X, rect.Origin.Y, rect.Size.Width, rect.Size.Height);
            }).ToArray();
        }
    }
    public bool KeyIsDown(ushort key) => QuartzNative.CGEventSourceKeyState(1, key);
    public bool ButtonIsDown(uint button) => QuartzNative.CGEventSourceButtonState(1, button);
    public double MonotonicSeconds => (double)Stopwatch.GetTimestamp() / Stopwatch.Frequency;
    public double DoubleClickInterval => QuartzNative.ReadDoubleClickInterval();
    public double DoubleClickDistance => 4; // Quartz points, independent of Retina pixel scaling.
    public void Post(MacEvent item)
    {
        // A private event source avoids importing the system's current modifier state.
        var source = QuartzNative.CGEventSourceCreate(-1);
        if (source == IntPtr.Zero) throw new InvalidOperationException("Could not create event source.");
        IntPtr nativeEvent = IntPtr.Zero;
        try
        {
            nativeEvent = item.Kind switch
            {
                MacEventKind.Mouse => QuartzNative.CGEventCreateMouseEvent(source, item.MouseType,
                    new() { X = item.Position.X, Y = item.Position.Y }, item.Button),
                MacEventKind.Key => QuartzNative.CGEventCreateKeyboardEvent(source, item.KeyCode, item.Down),
                // Non-variadic API is required for correct arm64 P/Invoke calling conventions.
                MacEventKind.Scroll => QuartzNative.CGEventCreateScrollWheelEvent2(source, 0, 2, item.DeltaY, item.DeltaX, 0),
                _ => throw new InvalidOperationException("Unsupported Quartz event.")
            };
            if (nativeEvent == IntPtr.Zero) throw new InvalidOperationException("Could not create input event.");
            QuartzNative.CGEventSetFlags(nativeEvent, item.Flags);
            if (item.Kind == MacEventKind.Mouse)
            {
                QuartzNative.CGEventSetIntegerValueField(nativeEvent, 1, item.ClickCount);
                QuartzNative.CGEventSetIntegerValueField(nativeEvent, 4, item.DeltaX);
                QuartzNative.CGEventSetIntegerValueField(nativeEvent, 5, item.DeltaY);
            }
            if (item.Unicode is { } text)
                QuartzNative.CGEventKeyboardSetUnicodeString(nativeEvent, (nuint)text.Length, text.Select(value => (ushort)value).ToArray());
            // Session tap stays within the logged-in user's GUI session. CGEventPost returns void.
            QuartzNative.CGEventPost(1, nativeEvent);
        }
        finally
        {
            if (nativeEvent != IntPtr.Zero) QuartzNative.CFRelease(nativeEvent);
            QuartzNative.CFRelease(source);
        }
    }
}

// Signatures verified against macOS SDK CoreGraphics/{CGEvent,CGEventSource,CGSession}.h,
// HIToolbox/Events.h, HIServices/AXUIElement.h and CoreFoundation headers.
internal static class QuartzNative
{
    private const string CG = "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics";
    private const string CF = "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation";
#if !SOFATAP_MAC_APP_STORE
    private const string AX = "/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices";
#endif
    // AppKit must remain loaded while its Objective-C classes are in use.
    private static readonly Lazy<IntPtr> AppKit = new(() => NativeLibrary.Load("/System/Library/Frameworks/AppKit.framework/AppKit"));
    internal static double ReadDoubleClickInterval()
    {
        try
        {
            _ = AppKit.Value;
            var eventClass = objc_getClass("NSEvent");
            var selector = sel_registerName("doubleClickInterval");
            if (eventClass != IntPtr.Zero && selector != IntPtr.Zero)
            {
                var interval = objc_msgSendDouble(eventClass, selector);
                if (double.IsFinite(interval) && interval > 0) return interval;
            }
        }
        catch (Exception error) when (error is DllNotFoundException or EntryPointNotFoundException or InvalidOperationException) { }
        return .5; // Keep single-click input usable if the optional preference cannot be read.
    }
    [StructLayout(LayoutKind.Sequential)] internal struct Point { public double X, Y; }
    [StructLayout(LayoutKind.Sequential)] internal struct Size { public double Width, Height; }
    [StructLayout(LayoutKind.Sequential)] internal struct Rect { public Point Origin; public Size Size; }
#if !SOFATAP_MAC_APP_STORE
    [DllImport(AX)] [return: MarshalAs(UnmanagedType.I1)] internal static extern bool AXIsProcessTrusted();
#endif
    [DllImport(CG)] [return: MarshalAs(UnmanagedType.I1)] internal static extern bool CGPreflightPostEventAccess();
    [DllImport(CG)] [return: MarshalAs(UnmanagedType.I1)] internal static extern bool CGRequestPostEventAccess();
    [DllImport(CG)] internal static extern IntPtr CGSessionCopyCurrentDictionary();
    [DllImport(CG)] internal static extern IntPtr CGEventCreate(IntPtr source);
    [DllImport(CG)] internal static extern IntPtr CGEventSourceCreate(int state);
    [DllImport(CG)] internal static extern Point CGEventGetLocation(IntPtr item);
    [DllImport(CG)] internal static extern int CGGetActiveDisplayList(uint count, [Out] uint[] displays, out uint actual);
    [DllImport(CG)] internal static extern Rect CGDisplayBounds(uint display);
    [DllImport(CG)] [return: MarshalAs(UnmanagedType.I1)] internal static extern bool CGEventSourceKeyState(int state, ushort key);
    [DllImport(CG)] [return: MarshalAs(UnmanagedType.I1)] internal static extern bool CGEventSourceButtonState(int state, uint button);
    [DllImport(CG)] internal static extern IntPtr CGEventCreateMouseEvent(IntPtr source, uint type, Point point, uint button);
    [DllImport(CG)] internal static extern IntPtr CGEventCreateKeyboardEvent(IntPtr source, ushort key, [MarshalAs(UnmanagedType.I1)] bool down);
    [DllImport(CG)] internal static extern IntPtr CGEventCreateScrollWheelEvent2(IntPtr source, uint units, uint count, int first, int second, int third);
    [DllImport(CG)] internal static extern void CGEventSetFlags(IntPtr item, ulong flags);
    [DllImport(CG)] internal static extern void CGEventSetIntegerValueField(IntPtr item, uint field, long value);
    [DllImport(CG)] internal static extern void CGEventKeyboardSetUnicodeString(IntPtr item, nuint length, [In] ushort[] text);
    [DllImport(CG)] internal static extern void CGEventPost(uint tap, IntPtr item);
    [DllImport(CF)] internal static extern void CFRelease(IntPtr value);
    [DllImport(CF)] internal static extern nuint CFGetTypeID(IntPtr value);
    [DllImport(CF)] internal static extern nuint CFBooleanGetTypeID();
    [DllImport(CF)] internal static extern nuint CFNumberGetTypeID();
    [DllImport(CF)] [return: MarshalAs(UnmanagedType.I1)] internal static extern bool CFBooleanGetValue(IntPtr value);
    [DllImport(CF)] [return: MarshalAs(UnmanagedType.I1)] internal static extern bool CFNumberGetValue(IntPtr value, int type, out int result);
    [DllImport(CF)] internal static extern IntPtr CFStringCreateWithCString(IntPtr allocator, [MarshalAs(UnmanagedType.LPUTF8Str)] string value, uint encoding);
    [DllImport(CF)] internal static extern IntPtr CFDictionaryGetValue(IntPtr dictionary, IntPtr key);
    [DllImport("/usr/lib/libSystem.B.dylib")] internal static extern uint geteuid();
    [DllImport("/usr/lib/libobjc.A.dylib")] private static extern IntPtr objc_getClass([MarshalAs(UnmanagedType.LPUTF8Str)] string name);
    [DllImport("/usr/lib/libobjc.A.dylib")] private static extern IntPtr sel_registerName([MarshalAs(UnmanagedType.LPUTF8Str)] string name);
    [DllImport("/usr/lib/libobjc.A.dylib", EntryPoint = "objc_msgSend")] private static extern double objc_msgSendDouble(IntPtr receiver, IntPtr selector);
}
