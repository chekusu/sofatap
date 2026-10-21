package com.chekusu.sofatap.controller;

import org.json.JSONObject;
import java.nio.charset.StandardCharsets;
import java.util.Iterator;
import java.util.Set;
import java.util.UUID;

/** Validated capability snapshot. Network connection alone never enables input. */
public final class ReceiverStatus {
    public final String name, platform, navigationStatus, editorEpoch, textStatus, focusState, inputStatus;
    public final int focusRevision;
    public final boolean ready, canMove, canClick, canScroll, canDrag, canRightClick, canNavigate, canBack, canHome, canText;
    private final boolean tv;

    private ReceiverStatus(boolean tv, String name, String platform, String inputStatus, boolean ready,
                           boolean move, boolean click, boolean scroll, boolean drag, boolean right,
                           boolean navigate, boolean back, boolean home, boolean text,
                           String navigationStatus, String editorEpoch, String textStatus, String focusState, int focusRevision) {
        this.tv = tv; this.name = name; this.platform = platform; this.inputStatus = inputStatus; this.ready = ready;
        canMove = move; canClick = click; canScroll = scroll; canDrag = drag; canRightClick = right;
        canNavigate = navigate; canBack = back; canHome = home; canText = text;
        this.navigationStatus = navigationStatus; this.editorEpoch = editorEpoch; this.textStatus = textStatus; this.focusState = focusState;
        this.focusRevision = focusRevision;
    }

    public static ReceiverStatus fromHello(JSONObject message, boolean tv) {
        if (message == null || !"hello".equals(message.opt("type")) || !integer(message.opt("version"), 1, 1)) throw invalid();
        String name = string(message, "name");
        if (!Pairing.validUnicode(name) || name.getBytes(StandardCharsets.UTF_8).length > (tv ? 128 : 256) || name.codePoints().anyMatch(Pairing::isControl) || tv && name.isEmpty()) throw invalid();
        String platform;
        if (tv) {
            if (!"androidtv".equals(message.opt("platform"))) throw invalid();
            platform = "androidtv";
            if (message.has("pairingToken") && (!(message.opt("pairingToken") instanceof String token) || !token.matches("[A-Za-z0-9_-]{43}"))) throw invalid();
        } else {
            Object value = message.opt("platform");
            platform = value instanceof String s && Set.of("windows", "macos", "linux").contains(s) ? s : "unknown";
        }
        return parse(message, tv, name, platform);
    }

    public ReceiverStatus withUpdate(JSONObject message) {
        if (message == null) throw invalid();
        boolean hasStatus = message.has("inputAvailable") || message.has("inputStatus") || message.has("capabilities") || message.has("tvControls");
        if (!hasStatus) return this;
        // A partial status is invalid rather than retaining a previous grant after revocation.
        if (!message.has("inputAvailable") || !message.has("inputStatus") || (!tv && !message.has("dryRun"))) throw invalid();
        return parse(message, tv, name, platform);
    }

    private static ReceiverStatus parse(JSONObject message, boolean tv, String name, String platform) {
        boolean available = bool(message, "inputAvailable");
        if (!tv) {
            boolean dry = message.has("dryRun") && bool(message, "dryRun");
            String status = message.has("inputStatus") ? string(message, "inputStatus") : available ? "ready" : "unavailable";
            boolean ready = available && !dry && "ready".equals(status);
            String focus = "unknown";
            int revision = -1;
            if (ready && message.opt("textFocus") instanceof JSONObject field && field.opt("state") instanceof String state &&
                Set.of("unknown", "other", "editable", "protected").contains(state) && integer(field.opt("revision"), 0, Integer.MAX_VALUE)) {
                focus = state;
                revision = ((Number) field.opt("revision")).intValue();
            }
            return new ReceiverStatus(false, name, platform, dry ? "dry_run" : status, ready,
                ready, ready, ready, ready, ready, false, ready, false, ready,
                "unsupported", null, "no_editor", focus, revision);
        }
        String input = string(message, "inputStatus");
        if (!Set.of("ready", "accessibility_required", "screen_locked", "unavailable").contains(input) || available != input.equals("ready")) throw invalid();
        JSONObject caps = object(message, "capabilities");
        boolean move = bool(caps, "overlayCursor"), click = bool(caps, "nodeClick"), scroll = bool(caps, "scroll"),
            back = bool(caps, "back"), home = bool(caps, "home");
        bool(caps, "directionalFocus");
        // These legacy false flags cannot be reinterpreted as new protocol capabilities.
        if (bool(caps, "text") || bool(caps, "rawMouse") || bool(caps, "rightClick") || bool(caps, "drag")) throw invalid();
        String navigation = "unsupported", text = "ime_required", editor = null;
        if (message.has("tvControls")) {
            JSONObject controls = object(message, "tvControls");
            Set<String> allowed = Set.of("version", "navigationStatus", "textStatus", "editorEpoch");
            for (Iterator<String> keys = controls.keys(); keys.hasNext();) if (!allowed.contains(keys.next())) throw invalid();
            if (!integer(controls.opt("version"), 1, 1)) throw invalid();
            navigation = string(controls, "navigationStatus"); text = string(controls, "textStatus");
            if (!Set.of("unsupported", "pairing_required", "pairing", "ready", "unavailable").contains(navigation) ||
                !Set.of("ime_required", "no_editor", "ready", "sensitive").contains(text)) throw invalid();
            if (controls.has("editorEpoch")) editor = canonicalUuid(string(controls, "editorEpoch"));
            if (text.equals("ready") != (editor != null)) throw invalid();
        }
        boolean navigate = navigation.equals("ready"), typing = text.equals("ready");
        // Screen-locked state overrides even a stale native-service capability.
        boolean unlocked = !input.equals("screen_locked");
        navigate &= unlocked; typing &= unlocked;
        return new ReceiverStatus(true, name, platform, input, available || navigate || typing,
            available && move, available && click, available && scroll, false, false,
            navigate, navigate || available && back, navigate || available && home, typing,
            navigation, typing ? editor : null, text, typing ? "editable" : text.equals("sensitive") ? "protected" : "unknown", -1);
    }

    static String canonicalUuid(String value) {
        try {
            String canonical = UUID.fromString(value).toString();
            if (!canonical.equalsIgnoreCase(value)) throw invalid();
            return canonical;
        } catch (Exception bad) { throw invalid(); }
    }
    private static boolean integer(Object value, int min, int max) {
        return value instanceof Number n && Double.isFinite(n.doubleValue()) && n.doubleValue() == Math.rint(n.doubleValue()) && n.doubleValue() >= min && n.doubleValue() <= max;
    }
    private static boolean bool(JSONObject value, String key) {
        if (!(value.opt(key) instanceof Boolean b)) throw invalid();
        return b;
    }
    private static String string(JSONObject value, String key) {
        if (!(value.opt(key) instanceof String s)) throw invalid();
        return s;
    }
    private static JSONObject object(JSONObject value, String key) {
        if (!(value.opt(key) instanceof JSONObject result)) throw invalid();
        return result;
    }
    private static IllegalArgumentException invalid() { return new IllegalArgumentException("Invalid receiver status"); }
}
