package com.chekusu.sofatap.controller;

import org.json.JSONArray;
import org.json.JSONObject;
import java.nio.charset.StandardCharsets;
import java.util.Locale;
import java.util.Set;
import java.util.UUID;

/** Produces only the receiver's bounded, allowlisted protocol-v1 commands. */
public final class WireActions {
    private WireActions() { }
    private static final Set<String> TV_KEYS = Set.of("up", "down", "left", "right", "confirm", "back", "home");
    private static final Set<String> DESKTOP_KEYS = Set.of("enter", "tab", "escape", "backspace", "delete", "up", "down", "left", "right", "home", "end", "pageup", "pagedown", "space", "a", "c", "v", "x", "z");

    public static JSONObject move(Pairing pairing, double dx, double dy) { return motion("move", dx, dy, 500); }
    /** Input deltas follow desktop wheel semantics; TV document scrolling has the opposite sign. */
    public static JSONObject scroll(Pairing pairing, double dx, double dy) {
        return motion("scroll", pairing.isTv() ? -dx : dx, pairing.isTv() ? -dy : dy, pairing.isTv() ? 500 : 1200);
    }
    public static JSONObject scroll(Pairing pairing, double dy) { return scroll(pairing, 0, dy); }
    public static JSONObject click(Pairing pairing, boolean right) {
        if (pairing.isTv()) { if (right) throw invalid(); return command("click"); }
        return put(command("click"), "button", right ? "right" : "left");
    }
    public static JSONObject button(boolean down) { return put(put(command("button"), "button", "left"), "down", down); }
    public static JSONObject button(Pairing pairing, boolean down) {
        if (pairing.isTv()) throw invalid();
        return button(down);
    }
    public static JSONObject key(Pairing pairing, String key, String platform) {
        if (key == null) throw invalid();
        if (pairing.isTv()) {
            if (!TV_KEYS.contains(key)) throw invalid();
            return put(command("remote_key"), "key", key);
        }
        String normalized = switch (key) {
            case "selectAll" -> "a"; case "copy" -> "c"; case "paste" -> "v"; case "cut" -> "x"; case "undo" -> "z";
            case "back" -> "escape"; case "confirm" -> "enter"; default -> key;
        };
        if (!DESKTOP_KEYS.contains(normalized)) throw invalid();
        JSONArray modifiers = new JSONArray();
        if (Set.of("a", "c", "v", "x", "z").contains(normalized)) modifiers.put("macos".equals(platform) ? "win" : "ctrl");
        return put(put(command("key"), "key", normalized), "modifiers", modifiers);
    }
    public static JSONObject key(Pairing pairing, ReceiverStatus status, String key) {
        if (pairing.isTv()) {
            if (status.canNavigate) return key(pairing, key, status.platform);
            if ("back".equals(key) && status.canBack || "home".equals(key) && status.canHome) return put(command("key"), "key", key);
            throw invalid();
        }
        if (!status.ready) throw invalid();
        return key(pairing, key, status.platform);
    }
    public static JSONObject text(Pairing pairing, ReceiverStatus status, String text) {
        if (!status.canText || text == null || text.isEmpty() || !validUnicode(text)) throw invalid();
        if (pairing.isTv()) {
            if (text.getBytes(StandardCharsets.UTF_8).length > 4096) throw invalid();
            return put(editorCommand("text_commit", status), "text", text);
        }
        if (text.length() > 16_000) throw invalid();
        JSONObject result = put(command("text"), "text", text);
        if (result.toString().getBytes(StandardCharsets.UTF_8).length > 65_536) throw invalid();
        return result;
    }
    public static JSONObject backspace(Pairing pairing, ReceiverStatus status) {
        if (!status.canText) throw invalid();
        return pairing.isTv() ? editorCommand("text_backspace", status) : key(pairing, "backspace", status.platform);
    }
    public static JSONObject enter(Pairing pairing, ReceiverStatus status) {
        if (!status.canText) throw invalid();
        return pairing.isTv() ? editorCommand("text_action", status) : key(pairing, "enter", status.platform);
    }
    public static JSONObject remotePairStart() { return command("remote_pair_start"); }
    public static JSONObject remotePairCode(String code) {
        if (code == null || !code.matches("[0-9A-Fa-f]{6}")) throw invalid();
        return put(command("remote_pair_code"), "code", code.toUpperCase(Locale.ROOT));
    }
    public static JSONObject ping() { return command("ping"); }
    public static JSONObject textBegin() { return command("textBegin"); }
    public static JSONObject textEnd(String session) { return put(command("textEnd"), "session", ReceiverStatus.canonicalUuid(session)); }
    public static JSONObject textSync(String session, int revision, LiveTextEditor.Snapshot snapshot) {
        if (revision < 1 || snapshot == null || !snapshot.valid()) throw invalid();
        JSONObject value = put(put(put(command("textSync"), "session", ReceiverStatus.canonicalUuid(session)), "revision", revision), "text", snapshot.text);
        put(value, "selectionStart", snapshot.selectionStart); put(value, "selectionLength", snapshot.selectionLength);
        if (value.toString().getBytes(StandardCharsets.UTF_8).length > 65_536) throw invalid();
        return value;
    }

    private static JSONObject motion(String type, double dx, double dy, int max) {
        if (!Double.isFinite(dx) || !Double.isFinite(dy) || Math.abs(dx) > max || Math.abs(dy) > max) throw invalid();
        return put(put(command(type), "dx", dx), "dy", dy);
    }
    private static JSONObject editorCommand(String type, ReceiverStatus status) {
        if (!status.canText || status.editorEpoch == null) throw invalid();
        return put(command(type), "editorEpoch", ReceiverStatus.canonicalUuid(status.editorEpoch));
    }
    private static JSONObject command(String type) { return put(put(new JSONObject(), "id", UUID.randomUUID().toString()), "type", type); }
    private static JSONObject put(JSONObject value, String key, Object field) {
        try { return value.put(key, field); } catch (Exception bad) { throw invalid(); }
    }
    private static boolean validUnicode(String value) {
        for (int index = 0; index < value.length(); index++) {
            char c = value.charAt(index);
            if (c == 0) return false;
            if (Character.isHighSurrogate(c)) { if (++index >= value.length() || !Character.isLowSurrogate(value.charAt(index))) return false; }
            else if (Character.isLowSurrogate(c)) return false;
        }
        return true;
    }
    private static IllegalArgumentException invalid() { return new IllegalArgumentException("Unsupported or invalid control action"); }
}
