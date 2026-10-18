using System.Text;
using System.Text.Json;
using SofaTap;

var passed = 0;
void Check(bool value, string name) { if (!value) throw new Exception("FAIL: " + name); passed++; }
ReceiverDistributionChecks.Run(Check);
// A focused non-interactive mode for the shared Mac: no server, native AX calls,
// permission requests or real input. Default runs still include the full suite.
if (args.Contains("--distribution-only", StringComparer.Ordinal))
{
    Console.WriteLine($"PASS: {passed} distribution checks (no network or desktop input).");
    return;
}
SystemVolumeChecks.Run(Check);
LinuxVolumeChecks.Run(Check);
await SystemVolumeWireChecks.Run(Check);
if (args.Contains("--volume-only", StringComparer.Ordinal))
{
    Console.WriteLine($"PASS: {passed} distribution and volume checks (fake audio/input and temporary TLS profiles only).");
    return;
}
PairingUriChecks.Run(Check);
CredentialPersistenceChecks.Run(Check);
LinuxInputChecks.Run(Check);
TextFocusChecks.Run(Check);
UnlockCapabilityChecks.Run(Check);
WindowsTextInputChecks.Run(Check);
LiveTextChecks.Run(Check);
WindowsLiveTextChecks.Run(Check);
#if !SOFATAP_MAC_APP_STORE
MacTextEditorChecks.Run(Check);
#endif
await LiveTextWireChecks.Run(Check);

var focusTracker = new TextFocusTracker();
Check(focusTracker.Update(new(TextFocusKind.Editable, "native-private-target"), false) == new TextFocusMetadata("unknown", 0), "unavailable desktop never exposes a focused field");
var firstFocus = focusTracker.Update(new(TextFocusKind.Editable, "native-private-target"), true);
Check(firstFocus.State == "editable" && firstFocus.Revision == 1, "new writable target advances focus revision");
Check(focusTracker.Update(new(TextFocusKind.Editable, "native-private-target"), true) == firstFocus, "steady target does not reopen dismissed keyboard");
Check(focusTracker.Update(new(TextFocusKind.Editable, "another-target"), true).Revision == 2, "switching writable fields advances focus revision");
Check(!JsonSerializer.Serialize(firstFocus).Contains("native-private-target"), "focus metadata never serializes native identities");
Check(focusTracker.Update(new(TextFocusKind.Protected, "password-target"), true).State == "protected", "protected target stays explicit");
Check(focusTracker.Update(new(TextFocusKind.Protected, "password-target"), false).State == "unknown", "lock clears current focus metadata");
ActionMessage Parse(string body) => Protocol.Parse(Encoding.UTF8.GetBytes(body));
string Message(string fields, string? id = null) => "{\"id\":\"" + (id ?? Guid.NewGuid().ToString("D")) + "\"," + fields + "}";
void Reject(string body, string name)
{
    try { Parse(body); throw new Exception("FAIL: accepted " + name); }
    catch (Exception error) when (error is ProtocolException or JsonException or InvalidOperationException) { passed++; }
}

foreach (var command in new[] { "refresh", "requestAccess", "quit" })
    Check(NativeDesktopBridge.ParseCommand(JsonSerializer.Serialize(new { type = command })) == command, "native command " + command);
foreach (var invalid in new[] { "{}", "[]", "{\"type\":\"exec\"}", "{\"type\":\"quit\",\"extra\":1}", "{\"type\":\"quit\",\"type\":\"refresh\"}", "{\"type\":1}", "secret-input" })
{
    try { NativeDesktopBridge.ParseCommand(invalid); throw new Exception("Invalid native command accepted"); }
    catch (InvalidDataException error) { Check(!error.Message.Contains(invalid), "native protocol rejects unknown commands without echoing data"); }
}

Check(WindowsInput.NativeInputSize == (IntPtr.Size == 8 ? 40 : 28), "native INPUT architecture layout");
Check(WindowsInput.NormalizeWindowsNewlines("a\nb\r\nc\rd") == "a\rb\rc\rd", "Windows newline normalization preserves one paragraph break");
Check(WindowsInput.NormalizeWindowsNewlines("hello👋") == "hello👋", "no appended Enter or changed surrogate pairs");
Check(WindowsInput.ShortcutFailureReleaseCount(0) == 0, "failed zero-input shortcut releases no unowned key");
Check(WindowsInput.ShortcutFailureReleaseCount(1) == 1 && WindowsInput.ShortcutFailureReleaseCount(2) == 2, "partial shortcut releases only accepted outstanding downs");
Check(WindowsInput.ShortcutFailureReleaseCount(3) == 1 && WindowsInput.ShortcutFailureReleaseCount(4) == 0, "completed keyups excluded from failure cleanup");
Check(!new DryRunInput().Available, "dry-run availability is false");
var moved = Parse(Message("\"type\":\"move\",\"dx\":0.25,\"dy\":-500"));
Check(moved.Dx == 0.25 && moved.Dy == -500, "fractional move range");
Check(Parse(Message("\"type\":\"scroll\",\"dx\":1200,\"dy\":-1200")).Dy == -1200, "scroll limits");
var text = "你好 Windows 👋\n第二行";
var committed = Parse(Message("\"type\":\"text\",\"text\":" + JsonSerializer.Serialize(text)));
Check(committed.Text == text && committed.Text.Length == text.Length, "Chinese emoji UTF-16 preserved");
Check(Parse(Message("\"type\":\"text\",\"text\":" + JsonSerializer.Serialize(new string('x', 16000)))).Text!.Length == 16000, "maximum text units");
Check(Parse(Message("\"type\":\"key\",\"key\":\"a\",\"modifiers\":[\"ctrl\"]")).Modifiers!.SequenceEqual(["ctrl"]), "allowed shortcut");
Reject(Message("\"type\":\"move\",\"dx\":500.1,\"dy\":0"), "move overflow");
Reject(Message("\"type\":\"move\",\"dx\":1e999,\"dy\":0"), "infinite numeric overflow");
Reject(Message("\"type\":\"scroll\",\"dx\":0,\"dy\":1201"), "scroll overflow");
Reject(Message("\"type\":\"click\",\"button\":\"middle\""), "unsupported button");
Reject(Message("\"type\":\"button\",\"button\":\"left\",\"down\":1"), "nonboolean down");
Reject(Message("\"type\":\"text\",\"text\":\"x\",\"extra\":1"), "unknown field");
Reject(Message("\"type\":\"text\",\"type\":\"ping\",\"text\":\"x\""), "duplicate field");
Reject(Message("\"type\":\"key\",\"key\":\"f12\",\"modifiers\":[]"), "unsupported key");
Reject(Message("\"type\":\"key\",\"key\":\"a\",\"modifiers\":[\"ctrl\",\"ctrl\"]"), "duplicate modifier");
Reject(Message("\"type\":\"key\",\"key\":\"a\",\"modifiers\":[\"meta\"]"), "unsupported modifier");
Reject(Message("\"type\":\"ping\"", "invalid"), "malformed UUID");
Reject(Message("\"type\":\"exec\",\"command\":\"calc\""), "executable command");
Reject(Message("\"type\":\"text\",\"text\":" + JsonSerializer.Serialize(new string('x', 16001))), "text overflow");
Reject(Message("\"type\":\"text\",\"text\":\"\\uD800\""), "unpaired surrogate");
Reject(Message("\"type\":\"text\",\"text\":\"\\u0000\""), "NUL text");
Reject(new string(' ', Protocol.MaximumFrameBytes + 1), "frame cap");
Reject("[]", "nonobject JSON");

var fake = new FakeInput(); var session = new ActionSession(fake);
Check(session.Execute(committed).Ok && fake.Count == 1, "successful injection acknowledged");
Check(session.Execute(committed).Ok && fake.Count == 1, "same action deduplicated");
Check(session.Execute(committed with { Id = committed.Id.ToUpperInvariant() }).Ok && fake.Count == 1, "UUID case deduplication");
Check(!session.Execute(committed with { Text = "different" }).Ok && fake.Count == 1, "conflicting ID rejected without injection");
Check(session.Execute(new(Guid.NewGuid().ToString("D"), "ping")).Ok && fake.Count == 1, "ping never injects");
fake.Fail = true;
var failed = committed with { Id = Guid.NewGuid().ToString("D") };
var rejected = session.Execute(failed);
Check(!rejected.Ok && rejected.Error!.StartsWith("input_partial:") && fake.Count == 2, "partial injection status propagated");
Check(!session.Execute(failed).Ok && fake.Count == 2, "failed partial action never retried");
var bounded = new ActionSession(new FakeInput(), 1);
Check(bounded.Execute(committed).Ok, "dedup bounded session first action");
try { bounded.Execute(committed with { Id = Guid.NewGuid().ToString("D") }); throw new Exception("FAIL: action cap accepted"); }
catch (ProtocolException) { passed++; }

var directory = Path.Combine(Path.GetTempPath(), "sofatap-host-tests-" + Guid.NewGuid().ToString("N"));
try
{
    string token; string fingerprint;
    using (var credentials = Credentials.LoadOrCreate(directory))
    {
        token = credentials.Token; fingerprint = credentials.Fingerprint;
        Check(token.Length == 43 && fingerprint.Length == 64, "random token and pin shape");
        Check(credentials.Certificate.HasPrivateKey, "TLS private key present");
        Check(credentials.Certificate.NotAfter.ToUniversalTime() - credentials.Certificate.NotBefore.ToUniversalTime() <= TimeSpan.FromDays(366), "certificate duration meets Apple SSL maximum validity constraint");
        Check(NetworkAddresses.LocalIPv4().All(address => credentials.CertificateIPv4.Contains(address)), "every advertised LAN address has certificate SAN");
        try { using var duplicate = Credentials.LoadOrCreate(directory); throw new Exception("FAIL: concurrent profile lock"); }
        catch (InvalidOperationException) { passed++; }
    }
    using (var credentials = Credentials.LoadOrCreate(directory))
        Check(credentials.Token == token && credentials.Fingerprint == fingerprint, "pairing persists across receiver restart");
    if (!OperatingSystem.IsWindows())
        Check(File.GetUnixFileMode(Path.Combine(directory, "pairing.dat")) == (UnixFileMode.UserRead | UnixFileMode.UserWrite), "pairing file user-only permissions");
}
finally { Directory.Delete(directory, true); }

// macOS backend coverage uses a recording sink only: no Quartz calls, prompts or real input.
var unavailableMacSink = new RecordingMacSink { StatusCode = "accessibility_required" };
var unavailableMac = new MacInput(unavailableMacSink);
Check(!unavailableMac.Available && unavailableMac.StatusCode == "accessibility_required" && unavailableMacSink.Events.Count == 0,
    "Mac availability is a pure permission check");
try { unavailableMac.Apply(new("", "click", Button: "left")); throw new Exception("FAIL: untrusted Mac input"); }
catch (InputInjectionException error) { Check(error.Message.StartsWith("input_unavailable:") && unavailableMacSink.Events.Count == 0, "Mac denies input without permission"); }
unavailableMacSink.StatusCode = "desktop_unavailable";
Check(!unavailableMac.Available, "Mac denies a locked or missing desktop");

var macSink = new RecordingMacSink(); var mac = new MacInput(macSink);
mac.Apply(new("", "button", Button: "left", Down: true));
mac.Apply(new("", "move", Dx: -150, Dy: -25));
Check(macSink.Events[^1] is { MouseType: 6, Button: 0 } && macSink.CursorPosition == new MacPoint(-50, 75),
    "Mac held left button generates a drag into the display left of the main display");
mac.Apply(new("", "button", Button: "left", Down: false));
mac.Apply(new("", "button", Button: "right", Down: true));
mac.Apply(new("", "move", Dx: 5, Dy: -500));
Check(macSink.Events[^1] is { MouseType: 7, Button: 1 } && macSink.CursorPosition.Y == -200,
    "Mac right drag preserves negative display coordinates and clamps at the display edge");
mac.ReleaseAll();
Check(macSink.HeldButtons.Count == 0 && macSink.Events[^1].MouseType == 4, "Mac disconnect releases only its held mouse button");
var releasedCount = macSink.Events.Count;
mac.ReleaseAll();
Check(macSink.Events.Count == releasedCount, "Mac repeated release does not emit unowned releases");
mac.Apply(new("", "move", Dx: .4)); mac.Apply(new("", "move", Dx: .4));
Check(macSink.Events.Count == releasedCount, "Mac subpixel pointer movement accumulates before posting");
mac.Apply(new("", "move", Dx: .4));
Check(macSink.Events.Count == releasedCount + 1 && macSink.Events[^1].DeltaX == 1 && macSink.Events[^1].MouseType == 5,
    "Mac fractional pointer remainder is preserved without stale drag state");
mac.Apply(new("", "scroll", Dx: .7, Dy: -.7)); mac.Apply(new("", "scroll", Dx: .7, Dy: -.7));
Check(macSink.Events[^1] is { Kind: MacEventKind.Scroll, DeltaX: 1, DeltaY: -1 }, "Mac both scroll axes preserve signed fractional deltas");
Check(MacInput.ClampToDisplays(new(210, 50), [new(0, 0, 100, 100), new(300, 0, 100, 100)]) == new MacPoint(300, 50),
    "Mac pointer in a monitor gap chooses the nearest real display rather than an invalid bounding-box point");

var clickingSink = new RecordingMacSink { DoubleClickInterval = .4, DoubleClickDistance = 3 };
var clickingMac = new MacInput(clickingSink);
clickingMac.Apply(new("", "click", Button: "left"));
clickingSink.MonotonicSeconds = .2;
clickingMac.Apply(new("", "move", Dx: 2));
clickingMac.Apply(new("", "click", Button: "left"));
clickingSink.MonotonicSeconds = .5;
clickingMac.Apply(new("", "click", Button: "left"));
Check(clickingSink.Events.Where(item => item.MouseType is 1 or 2).Select(item => item.ClickCount).SequenceEqual([1L, 1L, 2L, 2L, 3L, 3L]),
    "Mac nearby clicks within the system interval produce matching single, double and triple down/up counts");
clickingSink.MonotonicSeconds = 1;
clickingMac.Apply(new("", "click", Button: "left"));
Check(clickingSink.Events[^1].ClickCount == 1, "Mac clicks after the configured interval start a new sequence");
clickingMac.Apply(new("", "click", Button: "right"));
Check(clickingSink.Events[^1] is { Button: 1, ClickCount: 1 }, "Mac switching mouse buttons starts a new click sequence");
clickingMac.Apply(new("", "click", Button: "left"));
clickingMac.Apply(new("", "move", Dx: 4)); clickingMac.Apply(new("", "move", Dx: -4));
clickingMac.Apply(new("", "click", Button: "left"));
Check(clickingSink.Events[^1].ClickCount == 1, "Mac movement beyond tolerance resets click count even if the pointer returns");
clickingMac.ReleaseAll(); clickingMac.Apply(new("", "click", Button: "left"));
Check(clickingSink.Events[^1].ClickCount == 1, "Mac disconnect clears multi-click history");
clickingMac.Apply(new("", "button", Button: "left", Down: true));
var dragEventCount = clickingSink.Events.Count;
try { clickingMac.Apply(new("", "click", Button: "left")); throw new Exception("FAIL: Mac click interrupted drag"); }
catch (InputInjectionException error)
{
    Check(error.Message.StartsWith("input_busy:") && clickingSink.Events.Count == dragEventCount && clickingSink.HeldButtons.Contains(0),
        "Mac click during a remote drag is rejected without silently releasing the held button");
}
clickingMac.Apply(new("", "move", Dx: 1));
clickingMac.Apply(new("", "button", Button: "left", Down: false));
clickingMac.Apply(new("", "click", Button: "left"));
Check(clickingSink.Events[^1].ClickCount == 1, "Mac explicit dragging cannot merge with the previous click sequence");

var ctrlSink = new RecordingMacSink();
new MacInput(ctrlSink).Apply(new("", "key", Key: "a", Modifiers: ["ctrl"]));
Check(ctrlSink.Events[0] is { KeyCode: 0x3B, Flags: 0x40000 } && ctrlSink.Events[^1].Flags == 0,
    "Mac ctrl maps to real Control and releases its flags");
var commandSink = new RecordingMacSink();
new MacInput(commandSink).Apply(new("", "key", Key: "c", Modifiers: ["win", "shift"]));
Check(commandSink.Events[0] is { KeyCode: 0x37, Flags: 0x100000 }
    && commandSink.Events[2] is { KeyCode: 8, Down: true, Flags: 0x120000 }
    && commandSink.Events[^2] is { KeyCode: 0x38, Down: false, Flags: 0x100000 }
    && commandSink.Events[^1] is { KeyCode: 0x37, Down: false, Flags: 0 }, "Mac Command shortcut maintains and unwinds each modifier");
Check(commandSink.HeldKeys.Count == 0, "Mac successful shortcut leaves no held keys");
for (var interruptAt = 1; interruptAt <= 6; interruptAt++)
{
    var interruptedSink = new RecordingMacSink { FailAtPost = interruptAt };
    var interruptedMac = new MacInput(interruptedSink);
    try { interruptedMac.Apply(new("", "key", Key: "c", Modifiers: ["win", "shift"])); throw new Exception("FAIL: Mac interruption accepted"); }
    catch (InputInjectionException error)
    {
        Check(error.Message.StartsWith("input_partial:") && interruptedSink.HeldKeys.Count == 0 && interruptedSink.Events[^1].Flags == 0,
            $"Mac uncertain shortcut at event {interruptAt} releases all owned keys with no remaining modifier flags");
    }
}
var mouseFailureSink = new RecordingMacSink { FailAtPost = 1 };
try { new MacInput(mouseFailureSink).Apply(new("", "click", Button: "right")); throw new Exception("FAIL: Mac mouse interruption accepted"); }
catch (InputInjectionException error)
{
    Check(error.Message.StartsWith("input_partial:") && mouseFailureSink.HeldButtons.Count == 0 && mouseFailureSink.Events[^1].MouseType == 4,
        "Mac uncertain mouse down receives a matching release");
}
var physicalSink = new RecordingMacSink(); physicalSink.PhysicalKeys.Add(0x3E);
try { new MacInput(physicalSink).Apply(new("", "text", Text: "hello")); throw new Exception("FAIL: physical Control ignored"); }
catch (InputInjectionException error)
{
    Check(error.Message.StartsWith("input_busy:") && physicalSink.Events.Count == 0 && physicalSink.PhysicalKeys.Contains(0x3E),
        "Mac refuses text while right Control is physically down and never releases it");
}
var lockingSink = new RecordingMacSink(); var lockingMac = new MacInput(lockingSink);
lockingMac.Apply(new("", "button", Button: "left", Down: true));
lockingSink.StatusCode = "desktop_unavailable";
lockingMac.ReleaseAll();
Check(lockingSink.Events.Count == 1, "Mac release does not post into a locked desktop");
lockingSink.StatusCode = "ready";
lockingMac.ReleaseAll();
Check(lockingSink.Events.Count == 1, "Mac does not replay stale releases after the desktop returns");

var macText = new string('a', 19) + "👋中文\r\n日本語\r独立\n👨‍👩‍👧‍👦" + new string('z', 75);
var textSink = new RecordingMacSink(); new MacInput(textSink).Apply(new("", "text", Text: macText));
var chunks = textSink.Events.Where(item => item.Down).Select(item => item.Unicode!).ToArray();
Check(string.Concat(chunks) == macText.Replace("\r\n", "\n", StringComparison.Ordinal).Replace('\r', '\n').Replace('\n', '\r'),
    "Mac Unicode chunks reconstruct Chinese, emoji, ZWJ sequences and exactly one break per CRLF");
Check(chunks.All(chunk => chunk.Length <= 20 && !char.IsHighSurrogate(chunk[^1]) && !char.IsLowSurrogate(chunk[0])),
    "Mac Unicode boundary never splits UTF-16 surrogate pairs");
Check(textSink.Events.Count(item => item.Down && item.KeyCode == 0x24) == 3 && textSink.Events[^1].KeyCode != 0x24 && textSink.HeldKeys.Count == 0,
    "Mac sends only requested line breaks and leaves no text key held");
Check(string.Concat(MacInput.TextEvents(new string('文', 16000)).Where(item => item.Down).Select(item => item.Unicode)).Length == 16000,
    "Mac maximum protocol text is not truncated by Unicode chunking");
var partialTextSink = new RecordingMacSink { FailAtPost = 3 };
var macSession = new ActionSession(new MacInput(partialTextSink));
var partialTextAction = new ActionMessage(Guid.NewGuid().ToString("D"), "text", Text: macText);
var partialTextAck = macSession.Execute(partialTextAction);
Check(!partialTextAck.Ok && partialTextAck.Error!.StartsWith("input_partial:") && partialTextSink.HeldKeys.Count == 0,
    "Mac text interruption reports uncertainty and releases the current Unicode key");
var partialTextCount = partialTextSink.Events.Count;
Check(!macSession.Execute(partialTextAction).Ok && partialTextSink.Events.Count == partialTextCount,
    "Mac partially submitted text is never replayed for the same action ID");
var revokedSink = new RecordingMacSink { RevokeAfterPost = 1 };
var revokedMac = new MacInput(revokedSink);
try { revokedMac.Apply(new("", "key", Key: "c", Modifiers: ["win"])); throw new Exception("FAIL: Mac permission revocation ignored"); }
catch (InputInjectionException error)
{
    Check(error.Message.StartsWith("input_partial:") && revokedSink.Events.Count == 1 && !revokedMac.Available,
        "Mac permission revocation during a shortcut stops further posts and reports uncertain input");
}
Console.WriteLine("Mac input checks use a recording sink; physical macOS input and TCC prompts are not exercised.");
Console.WriteLine($"PASS: {passed} host checks. Windows physical input is not exercised by this runner.");

sealed class FakeInput : IInputInjector
{
    public int Count { get; private set; }
    public bool Fail { get; set; }
    public bool Available => true;
    public void Apply(ActionMessage action) { Count++; if (Fail) throw new InputInjectionException("input_partial: injected prefix; delivery uncertain"); }
    public void ReleaseAll() { }
}

sealed class RecordingMacSink : IMacEventSink
{
    public string StatusCode { get; set; } = "ready";
    public MacPoint CursorPosition { get; private set; } = new(100, 100);
    public IReadOnlyList<MacRect> Displays { get; } = [new(-500, -200, 500, 500), new(0, 0, 1000, 800)];
    public double MonotonicSeconds { get; set; }
    public double DoubleClickInterval { get; init; } = .5;
    public double DoubleClickDistance { get; init; } = 4;
    public List<MacEvent> Events { get; } = [];
    public HashSet<ushort> HeldKeys { get; } = [];
    public HashSet<uint> HeldButtons { get; } = [];
    public HashSet<ushort> PhysicalKeys { get; } = [];
    public int FailAtPost { get; init; }
    public int RevokeAfterPost { get; init; }
    private int _posts;
    public bool KeyIsDown(ushort key) => PhysicalKeys.Contains(key);
    public bool ButtonIsDown(uint button) => false;
    public void Post(MacEvent item)
    {
        Events.Add(item);
        if (item.Kind == MacEventKind.Key)
        {
            if (item.Down) HeldKeys.Add(item.KeyCode); else HeldKeys.Remove(item.KeyCode);
        }
        if (item.Kind == MacEventKind.Mouse)
        {
            CursorPosition = item.Position;
            if (item.MouseType is 1 or 3) HeldButtons.Add(item.Button);
            if (item.MouseType is 2 or 4) HeldButtons.Remove(item.Button);
        }
        _posts++;
        if (_posts == RevokeAfterPost) StatusCode = "accessibility_required";
        if (_posts == FailAtPost) throw new InvalidOperationException("Simulated unknown event-post result.");
    }
}
