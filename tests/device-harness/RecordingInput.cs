using System.Globalization;
using System.Text;
using System.Text.Json;
using SofaTap;

namespace SofaTap.DeviceHarness;

// Only owned memory and private test files are touched. This type has no OS input APIs.
internal sealed class RecordingInput : IInputInjector, IDisposable
{
    private const int MaxText = 160_000;
    private const long MaxLogBytes = 16 * 1024 * 1024;
    private readonly object gate = new();
    private readonly string directory;
    private readonly FileStream events;
    private readonly bool liveTextEnabled;
    private double x = 400, y = 250, scrollX, scrollY;
    private string text = "", focus = "notfocused", lastAction = "start";
    private int selectionStart, selectionLength, focusRevision, releases, leftClicks, rightClicks;
    private int liveReads, liveReplacements;
    private long sequence;
    private readonly HashSet<string> buttons = [];
    private readonly Dictionary<string, int> actions = new()
    { ["move"] = 0, ["click"] = 0, ["button"] = 0, ["scroll"] = 0, ["text"] = 0, ["key"] = 0 };
    public bool Available => true;

    public RecordingInput(string directory, bool liveTextEnabled = false)
    {
        this.directory = directory;
        this.liveTextEnabled = liveTextEnabled;
        events = PrivateFiles.Create(Path.Combine(directory, "events.jsonl"));
        Save();
    }

    public void Apply(ActionMessage action)
    {
        lock (gate)
        {
            try
            {
                if (events.Length >= MaxLogBytes) throw new InputInjectionException("input_unavailable: Recording limit reached.");
                RefreshControlLocked();
                if (!actions.ContainsKey(action.Type)) throw new InputInjectionException("input_unavailable: Unsupported recording action.");
                if (action.Type == "text")
                {
                    if (action.Text is null || IsPairingMaterial(action.Text))
                        throw new InputInjectionException("input_unavailable: Pairing material is not permitted in test text.");
                    if (text.Length - selectionLength + action.Text.Length > MaxText)
                        throw new InputInjectionException("input_unavailable: Test text limit reached.");
                }
                switch (action.Type)
                {
                    case "move": x = Math.Clamp(x + action.Dx, 0, 799); y = Math.Clamp(y + action.Dy, 0, 499); break;
                    case "click": if (action.Button == "left") leftClicks++; else rightClicks++; break;
                    case "button": if (action.Down) buttons.Add(action.Button!); else buttons.Remove(action.Button!); break;
                    case "scroll": scrollX += action.Dx; scrollY += action.Dy; break;
                    case "text": ReplaceSelection(action.Text!); break;
                    case "key": Key(action.Key!, action.Modifiers!); break;
                }
                actions[action.Type]++;
                sequence++;
                lastAction = action.Type;
                Log(new { sequence, at = DateTimeOffset.UtcNow, type = action.Type,
                    dx = action.Dx, dy = action.Dy, button = action.Button, down = action.Down,
                    key = action.Key, modifiers = action.Modifiers, text = action.Text,
                    pointer = new { x, y }, heldButtons = buttons.Order().ToArray() });
                Save();
            }
            catch (IOException) { throw new InputInjectionException("input_partial: Recording file write failed; no OS input occurred."); }
            catch (UnauthorizedAccessException) { throw new InputInjectionException("input_partial: Recording file access failed; no OS input occurred."); }
        }
    }

    internal static bool IsPairingMaterial(string value) =>
        value.Contains("sofatap://", StringComparison.OrdinalIgnoreCase)
        || value.Contains("fingerprint=", StringComparison.OrdinalIgnoreCase)
        || value.Contains("token=", StringComparison.OrdinalIgnoreCase)
        || value.Contains("-----BEGIN", StringComparison.Ordinal);

    private void ReplaceSelection(string value)
    {
        text = text.Remove(selectionStart, selectionLength).Insert(selectionStart, value);
        selectionStart += value.Length;
        selectionLength = 0;
    }

    private void Key(string key, IReadOnlyList<string> modifiers)
    {
        if (key == "a" && (modifiers.Contains("win") || modifiers.Contains("ctrl")))
        { selectionStart = 0; selectionLength = text.Length; return; }
        // Clipboard and application shortcuts are recorded only. No OS clipboard is used.
        if (modifiers.Count != 0) return;
        if (key is "enter" or "tab" or "space")
        {
            if (text.Length - selectionLength >= MaxText) throw new InputInjectionException("input_unavailable: Test text limit reached.");
            ReplaceSelection(key == "enter" ? "\n" : key == "tab" ? "\t" : " ");
        }
        else if (key is "backspace" or "delete")
        {
            if (selectionLength != 0) ReplaceSelection("");
            else if (key == "backspace" && selectionStart > 0)
            {
                var previous = StringInfo.ParseCombiningCharacters(text[..selectionStart]).Last();
                text = text.Remove(previous, selectionStart - previous); selectionStart = previous;
            }
            else if (key == "delete" && selectionStart < text.Length)
            {
                var length = StringInfo.GetNextTextElement(text, selectionStart).Length;
                text = text.Remove(selectionStart, length);
            }
        }
        else if (key == "home") { selectionStart = 0; selectionLength = 0; }
        else if (key == "end") { selectionStart = text.Length; selectionLength = 0; }
        else if (key == "escape") { focus = "notfocused"; focusRevision++; }
    }

    public void RefreshControl() { lock (gate) { if (RefreshControlLocked()) Save(); } }
    private bool RefreshControlLocked()
    {
        var path = Path.Combine(directory, "control.json");
        if (!PrivateFiles.IsRegularFile(path)) return false;
        try
        {
            if (new FileInfo(path).Length > 4096) return false;
            using var doc = JsonDocument.Parse(File.ReadAllText(path));
            var root = doc.RootElement;
            if (root.ValueKind != JsonValueKind.Object || root.EnumerateObject().Count() != 2
                || !root.TryGetProperty("focus", out var value) || value.ValueKind != JsonValueKind.String
                || !root.TryGetProperty("revision", out var revision) || revision.ValueKind != JsonValueKind.Number
                || !revision.TryGetInt32(out var nextRevision)
                || nextRevision < 0 || value.GetString() is not ("text" or "protected" or "notfocused")) return false;
            var nextFocus = value.GetString()!;
            if (nextRevision == focusRevision && nextFocus == focus) return false;
            focus = nextFocus; focusRevision = nextRevision;
            return true;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or JsonException) { return false; }
    }

    public TextFocusSnapshot Focus()
    {
        lock (gate)
        {
            if (RefreshControlLocked()) Save();
            return new(focus == "text" ? TextFocusKind.Editable : focus == "protected" ? TextFocusKind.Protected : TextFocusKind.Other,
                $"harness-{focus}-{focusRevision}");
        }
    }

    private TextEditorSnapshot LiveSnapshot()
    {
        if (!liveTextEnabled) throw new InputInjectionException("live_text_unsupported: Synthetic live editing was not enabled.");
        RefreshControlLocked();
        if (focus == "protected") throw new InputInjectionException("live_text_protected: Synthetic protected field.");
        if (focus != "text") throw new InputInjectionException("live_text_unsupported: No synthetic editable field.");
        return new($"harness-text-{focusRevision}", text, selectionStart, selectionLength);
    }

    public TextEditorSnapshot ReadLive()
    {
        lock (gate)
        {
            try
            {
                if (events.Length >= MaxLogBytes) throw new InputInjectionException("input_unavailable: Recording limit reached.");
                var snapshot = LiveSnapshot();
                LiveTextSession.ValidateText(snapshot.Text, snapshot.SelectionStart, snapshot.SelectionLength);
                liveReads++; sequence++; lastAction = "live_read";
                Log(new { sequence, at = DateTimeOffset.UtcNow, type = lastAction });
                Save();
                return snapshot;
            }
            catch (IOException) { throw new InputInjectionException("input_partial: Recording file write failed; no OS input occurred."); }
            catch (UnauthorizedAccessException) { throw new InputInjectionException("input_partial: Recording file access failed; no OS input occurred."); }
        }
    }

    public TextEditorSnapshot ReplaceLive(TextEditorSnapshot expected, string next, int start, int length)
    {
        lock (gate)
        {
            try
            {
                if (events.Length >= MaxLogBytes) throw new InputInjectionException("input_unavailable: Recording limit reached.");
                var current = LiveSnapshot();
                if (current != expected) throw new InputInjectionException("live_text_conflict: Synthetic field, contents or selection changed.");
                if (IsPairingMaterial(next)) throw new InputInjectionException("live_text_unsupported: Pairing material is not permitted in test text.");
                LiveTextSession.ValidateText(next, start, length);
                text = next; selectionStart = start; selectionLength = length;
                liveReplacements++; sequence++; lastAction = "live_replace";
                Log(new { sequence, at = DateTimeOffset.UtcNow, type = lastAction,
                    text, selectionStart, selectionLength });
                Save();
                return new(current.Target, text, selectionStart, selectionLength);
            }
            catch (IOException) { throw new InputInjectionException("input_partial: Recording file write failed; no OS input occurred."); }
            catch (UnauthorizedAccessException) { throw new InputInjectionException("input_partial: Recording file access failed; no OS input occurred."); }
        }
    }

    public void ReleaseAll()
    {
        lock (gate)
        {
            if (events.SafeFileHandle.IsClosed) return;
            var held = buttons.Order().ToArray();
            buttons.Clear(); releases++; sequence++; lastAction = "release";
            try { Log(new { sequence, at = DateTimeOffset.UtcNow, type = "release", releasedButtons = held }); Save(); }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
        }
    }

    private void Log(object item)
    {
        var bytes = Encoding.UTF8.GetBytes(JsonSerializer.Serialize(item, PrivateFiles.Json) + "\n");
        events.Write(bytes); events.Flush();
    }

    private void Save() => PrivateFiles.WriteJson(Path.Combine(directory, "state.json"), new
    {
        schemaVersion = 1, mode = "isolated-recording-only", osInjection = false,
        sequence, updatedAt = DateTimeOffset.UtcNow, width = 800, height = 500,
        pointer = new { x, y }, buttons = buttons.Order().ToArray(), clicks = new { left = leftClicks, right = rightClicks },
        scroll = new { x = scrollX, y = scrollY }, text, selection = new { start = selectionStart, length = selectionLength },
        liveText = new { enabled = liveTextEnabled, reads = liveReads, replacements = liveReplacements },
        actions, focus, focusRevision, releases, lastAction
    });

    public void Dispose() { ReleaseAll(); events.Dispose(); }
}

internal sealed class HarnessFocus(RecordingInput record) : ITextFocusProbe
{
    public TextFocusSnapshot Read() => record.Focus();
    public void Dispose() { }
}

// Shares only the recording sink's owned field, never a platform accessibility editor.
internal sealed class HarnessLiveTextEditor(RecordingInput record) : ILiveTextEditor
{
    public TextEditorSnapshot Read() => record.ReadLive();
    public TextEditorSnapshot Replace(TextEditorSnapshot expected, string text, int selectionStart, int selectionLength) =>
        record.ReplaceLive(expected, text, selectionStart, selectionLength);
    public void Dispose() { }
}
