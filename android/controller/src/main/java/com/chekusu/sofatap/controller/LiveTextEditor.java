package com.chekusu.sofatap.controller;

import org.json.JSONObject;
import java.nio.charset.StandardCharsets;
import java.util.Objects;

/** One acknowledged desktop field. Imported contents are ephemeral and must never be saved as drafts. */
public final class LiveTextEditor {
    public enum State { IDLE, STARTING, ACTIVE, SYNCING, UNSUPPORTED, PAUSED }
    public static final class Snapshot {
        public final String text;
        public final int selectionStart, selectionLength;
        public Snapshot(String text, int selectionStart, int selectionLength) {
            this.text = Objects.requireNonNull(text);
            this.selectionStart = selectionStart; this.selectionLength = selectionLength;
        }
        public boolean valid() {
            if (text.length() > 16000 || selectionStart < 0 || selectionLength < 0 || selectionStart > text.length()
                || selectionLength > text.length() - selectionStart) return false;
            int receiverBytes = 2;
            for (int index = 0; index < text.length(); index++) {
                char unit = text.charAt(index);
                if (unit == 0 || Character.isLowSurrogate(unit)) return false;
                if (Character.isHighSurrogate(unit)) {
                    if (++index >= text.length() || !Character.isLowSurrogate(text.charAt(index))) return false;
                    receiverBytes += 12; // System.Text.Json may escape both UTF-16 units.
                } else if (unit == '"' || unit == '\\' || unit == '\b' || unit == '\f' || unit == '\n' || unit == '\r' || unit == '\t') receiverBytes += 2;
                else {
                    int kind = Character.getType(unit);
                    if (unit < 32 || kind == Character.CONTROL || kind == Character.FORMAT || kind == Character.PRIVATE_USE
                        || kind == Character.UNASSIGNED || kind == Character.LINE_SEPARATOR || kind == Character.PARAGRAPH_SEPARATOR
                        || kind == Character.SPACE_SEPARATOR && unit != ' ') receiverBytes += 6;
                    else receiverBytes += unit < 128 ? 1 : unit < 2048 ? 2 : 3;
                }
                if (receiverBytes > 65536 - 1024) return false;
            }
            return boundary(selectionStart) && boundary(selectionStart + selectionLength)
                && JSONObject.quote(text).getBytes(StandardCharsets.UTF_8).length <= 65536 - 1024;
        }
        private boolean boundary(int index) {
            return index == 0 || index == text.length() || !(Character.isHighSurrogate(text.charAt(index - 1)) && Character.isLowSurrogate(text.charAt(index)));
        }
        public Snapshot replacingSelection(String inserted) {
            if (!valid() || inserted == null) throw invalid();
            Snapshot result = new Snapshot(text.substring(0, selectionStart) + inserted + text.substring(selectionStart + selectionLength), selectionStart + inserted.length(), 0);
            if (!result.valid()) throw invalid();
            return result;
        }
        static Snapshot fromWire(JSONObject object) {
            if (object == null || !(object.opt("text") instanceof String text)) throw invalid();
            Snapshot result = new Snapshot(text, integer(object.opt("selectionStart")), integer(object.opt("selectionLength")));
            if (!result.valid()) throw invalid();
            return result;
        }
        @Override public boolean equals(Object other) {
            return other instanceof Snapshot value && selectionStart == value.selectionStart && selectionLength == value.selectionLength && text.equals(value.text);
        }
        @Override public int hashCode() { return Objects.hash(text, selectionStart, selectionLength); }
        // Deliberately no toString: imported field contents must not enter logs or assertions.
    }

    private final RemoteSession remote;
    private State state = State.IDLE;
    private Snapshot baseline, desired, opening;
    private String sessionId, errorCode = "";
    private int revision, focusRevision;
    private long epoch, snapshotVersion;
    private boolean composing, imported;

    LiveTextEditor(RemoteSession remote) { this.remote = remote; }
    public State state() { return state; }
    public Snapshot snapshot() { return desired; }
    /** Incremented only when UI must apply an imported/canonical snapshot or clear it; local edits do not increment it. */
    public long snapshotVersion() { return snapshotVersion; }
    public boolean imported() { return imported; }
    public String errorCode() { return errorCode; }
    public boolean ready() { return state == State.ACTIVE || state == State.SYNCING; }
    public boolean composing() { return composing; }
    public String sessionId() { return sessionId; }
    // Enter, Backspace and other keys must not race a provisional or unacknowledged edit.
    boolean canSendKey() {
        return state == State.IDLE || state == State.UNSUPPORTED || state == State.ACTIVE && !dirty();
    }

    /** False leaves a retained explicit draft untouched. TV uses its explicit editor-epoch commit protocol. */
    public boolean open(Snapshot local, boolean marked) { return begin(local, marked, false); }
    /** User explicitly chooses to replace retained text with a fresh receiver snapshot. */
    public boolean restart(Snapshot local, boolean marked) {
        if (!canRead() || local == null || marked) return false;
        invalidate(false, true);
        state = State.IDLE;
        return begin(local, false, true);
    }
    private boolean begin(Snapshot local, boolean marked, boolean replace) {
        if (!canRead() || local == null || marked || !local.valid() || state == State.PAUSED && !replace) return false;
        if (ready() || state == State.STARTING) return true;
        if (!replace && (state == State.UNSUPPORTED || !imported && !local.text.isEmpty())) return false;
        opening = local; desired = local; composing = false; errorCode = "";
        state = State.STARTING; focusRevision = remote.status.focusRevision;
        long current = ++epoch;
        remote.liveTextChanged();
        boolean queued = remote.sendWithAck(WireActions.textBegin(), (result, ack) -> {
            if (current != epoch) return;
            if (result == RemoteSession.Result.ACCEPTED) {
                try {
                    if (!Objects.equals(opening, desired) || composing || !sameTarget()) throw invalid();
                    JSONObject reply = ack.getJSONObject("liveText");
                    String id = ReceiverStatus.canonicalUuid(reply.getString("session"));
                    if (integer(reply.opt("revision")) != 0) throw invalid();
                    Snapshot received = Snapshot.fromWire(reply);
                    sessionId = id; revision = 0; baseline = desired = received; opening = null;
                    imported = true; state = State.ACTIVE; snapshotVersion++; remote.liveTextChanged();
                } catch (Exception malformed) { pause("live_text_uncertain"); }
            } else if (result == RemoteSession.Result.REJECTED && "live_text_unsupported".equals(code(ack))) {
                state = State.UNSUPPORTED; opening = null; errorCode = "live_text_unsupported";
                if (imported) { desired = null; imported = false; snapshotVersion++; }
                remote.liveTextChanged();
            } else pause(result == RemoteSession.Result.REJECTED ? code(ack) : "live_text_uncertain");
        });
        if (!queued && current == epoch) pause("live_text_unavailable");
        return queued;
    }

    /** Call for text, UTF-16 selection and composition-only changes. Provisional IME text remains local. */
    public void edit(Snapshot local, boolean marked) {
        if (local == null) return;
        if (!ready() && state != State.STARTING) return;
        desired = local; composing = marked;
        if (state == State.STARTING && (!local.equals(opening) || marked)) { pause("live_text_changed"); return; }
        if (marked || state == State.STARTING) return;
        if (!local.valid()) { pause("live_text_invalid"); return; }
        flush();
    }
    private void flush() {
        if (state != State.ACTIVE || composing || desired == null || desired.equals(baseline)) return;
        if (!sameTarget() || sessionId == null || revision == Integer.MAX_VALUE || !desired.valid()) { pause("live_text_changed"); return; }
        Snapshot sent = desired; String id = sessionId; int nextRevision = revision + 1; long current = epoch;
        state = State.SYNCING; remote.liveTextChanged();
        boolean queued = remote.sendWithAck(WireActions.textSync(id, nextRevision, sent), (result, ack) -> {
            if (current != epoch) return;
            if (result != RemoteSession.Result.ACCEPTED) { pause(result == RemoteSession.Result.REJECTED ? code(ack) : "live_text_uncertain"); return; }
            try {
                JSONObject reply = ack.getJSONObject("liveText");
                if (!id.equals(reply.getString("session")) || integer(reply.opt("revision")) != nextRevision || !sameTarget()) throw invalid();
                Snapshot received = Snapshot.fromWire(reply);
                if (!received.equals(sent)) throw invalid();
                baseline = received; revision = nextRevision; state = State.ACTIVE;
                // The receiver must acknowledge the exact snapshot. No UI rewrite is needed;
                // a newer native IME edit may still be waiting for its callback.
                if (desired.equals(sent) && !composing) desired = received;
                remote.liveTextChanged(); flush();
            } catch (Exception malformed) { pause("live_text_uncertain"); }
        });
        if (!queued && current == epoch) pause("live_text_unavailable");
    }

    /** A clean end clears imported content; unsynchronized text pauses for explicit review without replay. */
    public void end() {
        if (state == State.PAUSED || state == State.UNSUPPORTED || state == State.IDLE) return;
        invalidate(dirty(), true); remote.liveTextChanged();
    }
    private void pause(String reason) { invalidate(true, true); errorCode = reason; remote.liveTextChanged(); }
    private boolean dirty() { return state == State.SYNCING || composing || imported && !Objects.equals(desired, baseline); }
    private void invalidate(boolean pause, boolean sendEnd) {
        String oldSession = sessionId;
        ++epoch; sessionId = null; baseline = null; opening = null; revision = 0; composing = false;
        state = pause ? State.PAUSED : State.IDLE;
        if (pause) errorCode = "live_text_changed";
        else { errorCode = ""; if (imported) { desired = null; imported = false; snapshotVersion++; } }
        remote.cancelQueuedLiveText();
        if (sendEnd && oldSession != null && remote.connected()) remote.sendWithAck(WireActions.textEnd(oldSession), null);
    }
    void disconnected() {
        if (state == State.PAUSED) return;
        invalidate(dirty(), false);
    }
    void resetTarget() {
        invalidate(false, false); desired = null; imported = false; state = State.IDLE; errorCode = "";
    }
    void receiverChanged(ReceiverStatus before, ReceiverStatus after) {
        boolean changed = before == null || before.focusRevision != after.focusRevision || !after.ready
            || !after.supportsLiveText || "protected".equals(after.focusState) || "other".equals(after.focusState);
        if (changed) {
            end();
            if (state == State.UNSUPPORTED) state = State.IDLE;
        }
    }
    private boolean canRead() {
        return remote.connected() && remote.pairing != null && !remote.pairing.isTv() && remote.status.ready
            && remote.status.supportsLiveText && !"protected".equals(remote.status.focusState) && !"other".equals(remote.status.focusState);
    }
    private boolean sameTarget() { return canRead() && remote.status.focusRevision == focusRevision; }
    static int integer(Object value) {
        if (!(value instanceof Number n) || !Double.isFinite(n.doubleValue()) || n.doubleValue() != Math.rint(n.doubleValue())
            || n.doubleValue() < 0 || n.doubleValue() > Integer.MAX_VALUE) throw invalid();
        return n.intValue();
    }
    private static String code(JSONObject ack) {
        if (ack != null && ack.opt("error") instanceof String error) {
            String prefix = error.split(":", 2)[0];
            if (java.util.Set.of("live_text_unsupported", "live_text_conflict", "live_text_uncertain", "live_text_protected", "input_unavailable", "input_busy").contains(prefix)) return prefix;
        }
        return "live_text_uncertain";
    }
    private static IllegalArgumentException invalid() { return new IllegalArgumentException("Invalid live text snapshot"); }
}
