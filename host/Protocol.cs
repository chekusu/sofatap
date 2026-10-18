using System.Text.Json;
using System.Security.Cryptography;

namespace SofaTap;

public sealed record ActionMessage(string Id, string Type, double Dx = 0, double Dy = 0,
    string? Button = null, bool Down = false, string? Key = null, string[]? Modifiers = null, string? Text = null,
    string? Session = null, int Revision = 0, int SelectionStart = 0, int SelectionLength = 0, string? Command = null);
public sealed record ActionAck(string Type, string Id, bool Ok, string? Error = null, LiveTextSnapshot? LiveText = null)
{
    public static ActionAck Success(string id) => new("ack", id, true);
    public static ActionAck Failure(string id, string error) => new("ack", id, false, error);
}
public sealed class ProtocolException(string message) : Exception(message);

public static class Protocol
{
    public const int MaximumFrameBytes = 65_536;
    public const int MaximumTextUnits = 16_000;
    public static readonly HashSet<string> Keys = ["enter", "tab", "escape", "backspace", "delete", "up", "down", "left", "right", "home", "end", "pageup", "pagedown", "space", "a", "c", "v", "x", "z"];
    public static readonly HashSet<string> ModifierKeys = ["ctrl", "alt", "shift", "win"];

    public static ActionMessage Parse(ReadOnlyMemory<byte> utf8)
    {
        if (utf8.Length > MaximumFrameBytes) throw new ProtocolException("Frame exceeds 64 KiB.");
        using var document = JsonDocument.Parse(utf8, new JsonDocumentOptions { MaxDepth = 8 });
        var root = document.RootElement;
        if (root.ValueKind != JsonValueKind.Object) throw new ProtocolException("Expected a JSON object.");
        var fields = new Dictionary<string, JsonElement>(StringComparer.Ordinal);
        foreach (var property in root.EnumerateObject())
            if (!fields.TryAdd(property.Name, property.Value)) throw new ProtocolException("Duplicate JSON field.");
        var id = String(fields, "id");
        if (!Guid.TryParseExact(id, "D", out _)) throw new ProtocolException("Action id must be a UUID.");
        var type = String(fields, "type");
        string[] allowed = type switch
        {
            "move" or "scroll" => ["id", "type", "dx", "dy"],
            "click" => ["id", "type", "button"],
            "button" => ["id", "type", "button", "down"],
            "key" => ["id", "type", "key", "modifiers"],
            "volume" => ["id", "type", "command"],
            "text" => ["id", "type", "text"],
            "textBegin" => ["id", "type"],
            "textEnd" => ["id", "type", "session"],
            "textSync" => ["id", "type", "session", "revision", "text", "selectionStart", "selectionLength"],
            "ping" => ["id", "type"],
            _ => throw new ProtocolException("Unsupported action type.")
        };
        if (fields.Count != allowed.Length || fields.Keys.Any(key => !allowed.Contains(key)))
            throw new ProtocolException("Missing or unknown action fields.");
        switch (type)
        {
            case "volume":
                var command = String(fields, "command");
                if (command is not ("up" or "down" or "mute")) throw new ProtocolException("Unsupported volume command.");
                return new(id, type, Command: command);
            case "textEnd":
                return new(id, type, Session: Session(fields));
            case "textSync":
                var editText = String(fields, "text");
                var start = Integer(fields, "selectionStart");
                var length = Integer(fields, "selectionLength");
                try { LiveTextSession.ValidateText(editText, start, length); }
                catch (InputInjectionException) { throw new ProtocolException("Invalid live text or selection."); }
                return new(id, type, Text: editText, Session: Session(fields), Revision: Integer(fields, "revision"),
                    SelectionStart: start, SelectionLength: length);
            case "move": case "scroll":
                var limit = type == "move" ? 500 : 1200;
                return new(id, type, Number(fields, "dx", limit), Number(fields, "dy", limit));
            case "click": case "button":
                var button = String(fields, "button");
                if (button is not ("left" or "right")) throw new ProtocolException("Unsupported mouse button.");
                var down = type == "button" && Boolean(fields, "down");
                return new(id, type, Button: button, Down: down);
            case "key":
                var key = String(fields, "key");
                if (!Keys.Contains(key)) throw new ProtocolException("Unsupported key.");
                if (fields["modifiers"].ValueKind != JsonValueKind.Array || fields["modifiers"].GetArrayLength() > 4)
                    throw new ProtocolException("Invalid modifiers.");
                var modifiers = fields["modifiers"].EnumerateArray().Select(item => item.ValueKind == JsonValueKind.String ? item.GetString()! : "").ToArray();
                if (modifiers.Any(modifier => !ModifierKeys.Contains(modifier)) || modifiers.Distinct().Count() != modifiers.Length)
                    throw new ProtocolException("Invalid or duplicate modifiers.");
                return new(id, type, Key: key, Modifiers: modifiers);
            case "text":
                var text = String(fields, "text");
                if (text.Length > MaximumTextUnits) throw new ProtocolException("Text exceeds 16000 UTF-16 units.");
                for (var index = 0; index < text.Length; index++)
                {
                    if (char.IsHighSurrogate(text[index]))
                    {
                        if (++index >= text.Length || !char.IsLowSurrogate(text[index])) throw new ProtocolException("Unpaired UTF-16 surrogate.");
                    }
                    else if (char.IsLowSurrogate(text[index])) throw new ProtocolException("Unpaired UTF-16 surrogate.");
                    else if (text[index] == '\0') throw new ProtocolException("NUL text is unsupported.");
                }
                return new(id, type, Text: text);
            default: return new(id, type);
        }
    }

    public static string TryReadId(ReadOnlyMemory<byte> bytes)
    {
        try
        {
            using var document = JsonDocument.Parse(bytes, new JsonDocumentOptions { MaxDepth = 8 });
            if (document.RootElement.ValueKind == JsonValueKind.Object && document.RootElement.TryGetProperty("id", out var id)
                && id.ValueKind == JsonValueKind.String && Guid.TryParseExact(id.GetString(), "D", out _)) return id.GetString()!;
        }
        catch (JsonException) { }
        return "";
    }
    private static string String(Dictionary<string, JsonElement> fields, string key)
    {
        if (!fields.TryGetValue(key, out var item) || item.ValueKind != JsonValueKind.String) throw new ProtocolException($"Missing or invalid {key}.");
        try { return item.GetString()!; }
        catch (InvalidOperationException) { throw new ProtocolException("Invalid JSON string."); }
    }
    private static string Session(Dictionary<string, JsonElement> fields)
    {
        var value = String(fields, "session");
        return Guid.TryParseExact(value, "D", out var parsed) ? parsed.ToString("D") : throw new ProtocolException("Invalid editing session.");
    }
    private static int Integer(Dictionary<string, JsonElement> fields, string key)
    {
        if (!fields.TryGetValue(key, out var item) || !item.TryGetInt32(out var value) || value < 0 || value == int.MaxValue)
            throw new ProtocolException("Invalid editing integer.");
        return value;
    }
    private static double Number(Dictionary<string, JsonElement> fields, string key, double limit)
    {
        if (!fields.TryGetValue(key, out var item) || item.ValueKind != JsonValueKind.Number || !item.TryGetDouble(out var number)
            || !double.IsFinite(number) || Math.Abs(number) > limit) throw new ProtocolException($"Invalid or out-of-range {key}.");
        return number;
    }
    private static bool Boolean(Dictionary<string, JsonElement> fields, string key)
    {
        if (!fields.TryGetValue(key, out var item) || item.ValueKind is not (JsonValueKind.True or JsonValueKind.False)) throw new ProtocolException($"Invalid {key}.");
        return item.GetBoolean();
    }
}

public sealed class ActionSession(IInputInjector input, int maximumActions = 131_072, LiveTextSession? liveText = null,
    ISystemVolume? systemVolume = null)
{
    private readonly Dictionary<Guid, (ActionAck Ack, byte[] Digest)> _seen = [];
    private int _cachedTextUnits;
    public ActionAck Execute(ActionMessage action)
    {
        var guid = Guid.Parse(action.Id);
        var canonical = action with { Id = guid.ToString("D") };
        var digest = SHA256.HashData(JsonSerializer.SerializeToUtf8Bytes(canonical));
        if (_seen.TryGetValue(guid, out var previous))
            return CryptographicOperations.FixedTimeEquals(digest, previous.Digest)
                ? previous.Ack with { Id = action.Id }
                : ActionAck.Failure(action.Id, "Action id reused for different content.");
        if (_seen.Count >= maximumActions) throw new ProtocolException("Session action limit reached. Reconnect before sending a new action.");
        if (_cachedTextUnits > 8_000_000 - Protocol.MaximumTextUnits)
            throw new ProtocolException("Session action limit reached. Reconnect before sending a new action.");
        ActionAck ack;
        try
        {
            if (action.Type == "volume")
            {
                if (systemVolume is null) throw new InputInjectionException("volume_unsupported: System volume is unavailable on this receiver.");
                if (!input.Available) throw new InputInjectionException("input_unavailable: Unlock the computer and enable desktop control before changing volume.");
                // System audio does not move the caret or disturb a held pointer button.
                systemVolume.Apply(action.Command!);
                ack = ActionAck.Success(action.Id);
            }
            else if (action.Type is "textBegin" or "textSync" or "textEnd")
            {
                if (liveText is null) throw new InputInjectionException("live_text_unsupported: This receiver cannot edit the focused field.");
                LiveTextSnapshot? snapshot = null;
                if (action.Type == "textBegin") snapshot = liveText.Begin();
                else if (action.Type == "textSync") snapshot = liveText.Sync(action.Session!, action.Revision, action.Text!, action.SelectionStart, action.SelectionLength);
                else liveText.End(action.Session);
                ack = ActionAck.Success(action.Id) with { LiveText = snapshot };
            }
            else
            {
                // A desktop action can change the caret/target. Pointer motion alone
                // does not invalidate typing; clicks, keys and drag initiation do.
                if (action.Type is "click" or "key" or "text" || action.Type == "button" && action.Down) liveText?.End();
                if (action.Type != "ping") input.Apply(action);
                ack = ActionAck.Success(action.Id);
            }
        }
        catch (InputInjectionException error) { ack = ActionAck.Failure(action.Id, error.Message); }
        // Cache failures too: a partial Windows injection must never be repeated.
        _seen.Add(guid, (ack, digest));
        _cachedTextUnits += ack.LiveText?.Text.Length ?? 0;
        return ack;
    }
}
