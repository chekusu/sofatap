package com.chekusu.sofatap.tv;

import org.json.JSONObject;
import org.json.JSONTokener;
import java.util.HashSet;
import java.util.Set;
import java.util.UUID;

/** Deliberately narrow manual-control wire format. No arbitrary Android intents or scripts. */
public final class TVProtocol {
    public record Action(String id, String type, double dx, double dy, String key, String code, String editorEpoch, String text) {
        public Action(String id, String type, double dx, double dy, String key) { this(id, type, dx, dy, key, null, null, null); }
        public boolean extended() { return type.startsWith("remote_") || type.startsWith("text_"); }
    }
    public static Action parse(String text) throws Exception {
        if (text.indexOf('\0') >= 0 || text.length() > WebSocketCodec.MAX_MESSAGE) throw new IllegalArgumentException("invalid_json");
        validateLexicalForm(text);
        // Android JSONObject silently overwrites duplicate fields. Scan the envelope
        // ourselves and reject duplicates before JSONObject sees it.
        JSONTokener t = new JSONTokener(text);
        if (t.nextClean() != '{') throw new IllegalArgumentException("object_required");
        Set<String> keys = new HashSet<>();
        JSONObject o = new JSONObject();
        char c = t.nextClean();
        if (c != '}') {
            t.back();
            while (true) {
                if (t.nextClean() != '"') throw new IllegalArgumentException("invalid_key");
                String key = t.nextString('"');
                if (!keys.add(key) || t.nextClean() != ':') throw new IllegalArgumentException("duplicate_or_invalid_field");
                char start = t.nextClean();
                Object value;
                if (start == '"') { value = t.nextString('"'); }
                else {
                    StringBuilder number = new StringBuilder();
                    char digit = start;
                    while (digit != ',' && digit != '}' && digit != 0) {
                        if (number.length() >= 64) throw new IllegalArgumentException("invalid_number");
                        number.append(digit); digit = t.next();
                    }
                    if (digit != 0) t.back();
                    String raw = number.toString().trim();
                    if (!raw.matches("-?(0|[1-9][0-9]*)(\\.[0-9]+)?([eE][+-]?[0-9]+)?"))
                        throw new IllegalArgumentException("invalid_value");
                    value = Double.parseDouble(raw);
                }
                o.put(key, value);
                c = t.nextClean();
                if (c == '}') break;
                if (c != ',') throw new IllegalArgumentException("invalid_object");
            }
        }
        if (t.nextClean() != 0) throw new IllegalArgumentException("trailing_data");
        String id = string(o, "id");
        if (!UUID.fromString(id).toString().equalsIgnoreCase(id)) throw new IllegalArgumentException("invalid_id");
        String type = string(o, "type");
        Set<String> allowed;
        double dx = 0, dy = 0; String key = null, code = null, editorEpoch = null, content = null;
        switch (type) {
            case "move": case "scroll":
                allowed = Set.of("id", "type", "dx", "dy");
                dx = number(o, "dx", type.equals("move") ? 500 : 1200);
                dy = number(o, "dy", type.equals("move") ? 500 : 1200); break;
            case "click": case "ping": case "remote_pair_start": allowed = Set.of("id", "type"); break;
            case "key": case "remote_key":
                allowed = Set.of("id", "type", "key"); key = string(o, "key");
                if (!Set.of("back", "home", "up", "down", "left", "right", "confirm").contains(key))
                    throw new IllegalArgumentException("unsupported_key");
                break;
            case "remote_pair_code":
                allowed = Set.of("id", "type", "code"); code = string(o, "code");
                if (!code.matches("[0-9a-fA-F]{6}")) throw new IllegalArgumentException("invalid_pair_code");
                break;
            case "text_commit": case "text_backspace": case "text_action":
                allowed = type.equals("text_commit") ? Set.of("id", "type", "editorEpoch", "text") : Set.of("id", "type", "editorEpoch");
                editorEpoch = string(o, "editorEpoch");
                UUID parsedEpoch = UUID.fromString(editorEpoch);
                if (!parsedEpoch.toString().equalsIgnoreCase(editorEpoch)) throw new IllegalArgumentException("invalid_editor_epoch");
                // Foundation sends uppercase UUIDs; compare the same canonical value to the Java IME epoch.
                editorEpoch = parsedEpoch.toString();
                if (type.equals("text_commit")) {
                    content = string(o, "text");
                    if (content.isEmpty() || content.indexOf('\0') >= 0 || content.getBytes(java.nio.charset.StandardCharsets.UTF_8).length > 4096)
                        throw new IllegalArgumentException("invalid_text");
                    for (int i = 0; i < content.length(); i++) {
                        char value = content.charAt(i);
                        if (Character.isHighSurrogate(value)) { if (++i >= content.length() || !Character.isLowSurrogate(content.charAt(i))) throw new IllegalArgumentException("invalid_text"); }
                        else if (Character.isLowSurrogate(value)) throw new IllegalArgumentException("invalid_text");
                    }
                }
                break;
            default: throw new IllegalArgumentException("unsupported_action");
        }
        if (!keys.equals(allowed)) throw new IllegalArgumentException("unexpected_fields");
        return new Action(id, type, dx, dy, key, code, editorEpoch, content);
    }
    private static void validateLexicalForm(String text) {
        // Android's tokenizer accepts comments/lenient escapes; JVM org.json differs.
        // Keep this wire subset identical on both providers before tokenization.
        boolean quoted = false;
        for (int i = 0; i < text.length(); i++) {
            char c = text.charAt(i);
            if (quoted) {
                if (c < 32) throw new IllegalArgumentException("invalid_json");
                if (c == '"') quoted = false;
                else if (c == '\\') {
                    if (++i >= text.length()) throw new IllegalArgumentException("invalid_json");
                    char escape = text.charAt(i);
                    if (escape == 'u') {
                        for (int n = 0; n < 4; n++) {
                            if (++i >= text.length() || Character.digit(text.charAt(i), 16) < 0 || text.charAt(i) > 127)
                                throw new IllegalArgumentException("invalid_json");
                        }
                    } else if ("\"\\/bfnrt".indexOf(escape) < 0) throw new IllegalArgumentException("invalid_json");
                }
            } else if (c == '"') quoted = true;
            else if (c == '/' || c == '#' || c == '\'' || c == '\uFEFF' || (c < 32 && c != '\n' && c != '\r' && c != '\t'))
                throw new IllegalArgumentException("invalid_json");
        }
        if (quoted) throw new IllegalArgumentException("invalid_json");
    }
    private static String string(JSONObject o, String key) throws Exception {
        Object value = o.get(key);
        if (!(value instanceof String)) throw new IllegalArgumentException("invalid_string");
        return (String)value;
    }
    private static double number(JSONObject o, String key, double limit) throws Exception {
        Object value = o.get(key);
        if (!(value instanceof Number)) throw new IllegalArgumentException("invalid_number");
        double number = ((Number)value).doubleValue();
        if (!Double.isFinite(number) || Math.abs(number) > limit) throw new IllegalArgumentException("invalid_number");
        return number;
    }
    public static JSONObject ack(String id, boolean ok, String error) throws Exception {
        JSONObject value = new JSONObject().put("type", "ack").put("id", id).put("ok", ok);
        if (error != null) value.put("error", error);
        return value;
    }
}
