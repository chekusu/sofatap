package com.chekusu.sofatap.tv.ui;

/**
 * The TV receiver's screen sequence, kept free of Android so it can be unit tested.
 *
 * First run: allow TV control (accessibility) first, then the pairing QR, the pairing animation,
 * a two-step gesture guide driven by real phone input, and the "every screen" hint. Later runs
 * open on the QR (while unpaired) or the idle screen. Permission comes back if it is revoked.
 */
public final class OnboardingFlow {
    public enum Stage { STOPPED, PREPARING, ERROR, PERMISSION, READY, LINKING, CONNECTED, GUIDE_MOVE, GUIDE_TAP, SCREENS, IDLE }

    /** What the receiver reports on each refresh. */
    public static final class Inputs {
        public boolean running, serverReady, error, qrAvailable, connected, needsPermission;
        public Inputs set(boolean running, boolean serverReady, boolean error, boolean qrAvailable, boolean connected, boolean needsPermission) {
            this.running = running; this.serverReady = serverReady; this.error = error;
            this.qrAvailable = qrAvailable; this.connected = connected; this.needsPermission = needsPermission; return this;
        }
    }

    public static final long LINKING_MS = 1700, CONNECTED_MS = 3200, SCREENS_MS = 8000, GUIDE_TIMEOUT_MS = 25000, TAP_GRACE_MS = 700;
    public static final int MOVES_TO_ADVANCE = 14;

    private Stage stage;
    private long enteredAt;
    private boolean onboarded, permissionDeferred;
    private int moves;
    private Inputs last = new Inputs();

    public OnboardingFlow(boolean onboarded) { this.onboarded = onboarded; }

    public Stage stage() { return stage; }
    public boolean onboarded() { return onboarded; }
    public long enteredAt() { return enteredAt; }

    /** Re-evaluates the stage from the receiver state; returns true when the stage changed. */
    public boolean update(Inputs in, long now) {
        last = in;
        Stage next = decide(in, now);
        if (next == stage) return false;
        enter(next, now);
        return true;
    }

    private Stage decide(Inputs in, long now) {
        if (!in.running) return Stage.STOPPED;
        if (in.error) return Stage.ERROR;
        if (!in.serverReady) return Stage.PREPARING;
        if (!in.needsPermission) permissionDeferred = false;
        long age = now - enteredAt;
        if (stage == null || stage == Stage.STOPPED || stage == Stage.ERROR || stage == Stage.PREPARING) return entry(in);
        switch (stage) {
            case PERMISSION:
                if (in.needsPermission) return Stage.PERMISSION;
                return afterPermission(in);
            case READY:
                if (in.connected) return Stage.LINKING;
                if (in.needsPermission && !permissionDeferred && !onboarded) return Stage.PERMISSION;
                return in.qrAvailable ? Stage.READY : Stage.IDLE;
            case LINKING:
                return age >= LINKING_MS ? Stage.CONNECTED : Stage.LINKING;
            case CONNECTED:
                if (age < CONNECTED_MS) return Stage.CONNECTED;
                if (in.needsPermission) return permissionDeferred ? Stage.IDLE : Stage.PERMISSION;
                return onboarded ? Stage.IDLE : Stage.GUIDE_MOVE;
            case GUIDE_MOVE:
                // The phone left (or New pairing revoked it): show the code again instead of the guide.
                if (!in.connected) return lostPhone(in);
                if (in.needsPermission) return Stage.PERMISSION;
                return age >= GUIDE_TIMEOUT_MS ? Stage.GUIDE_TAP : Stage.GUIDE_MOVE;
            case GUIDE_TAP:
                if (!in.connected) return lostPhone(in);
                if (in.needsPermission) return Stage.PERMISSION;
                return age >= GUIDE_TIMEOUT_MS ? Stage.SCREENS : Stage.GUIDE_TAP;
            case SCREENS:
                if (!in.connected) return lostPhone(in);
                return age >= SCREENS_MS ? finish() : Stage.SCREENS;
            case IDLE:
            default:
                if (in.qrAvailable && !in.connected) return Stage.READY;
                if (in.needsPermission && !permissionDeferred) return Stage.PERMISSION;
                return Stage.IDLE;
        }
    }

    private Stage entry(Inputs in) {
        if (in.needsPermission && !permissionDeferred) return Stage.PERMISSION;
        if (in.connected && !onboarded) return Stage.CONNECTED;
        return in.qrAvailable && !in.connected ? Stage.READY : Stage.IDLE;
    }

    private Stage afterPermission(Inputs in) {
        if (in.qrAvailable && !in.connected) return Stage.READY;
        if (in.connected && !onboarded) return Stage.GUIDE_MOVE;
        return Stage.IDLE;
    }

    private Stage lostPhone(Inputs in) { return in.qrAvailable ? Stage.READY : Stage.IDLE; }

    private Stage finish() { onboarded = true; return Stage.IDLE; }

    /** The primary/skip action on the current stage: OK on the remote, "Later", "Skip", "Done". */
    public boolean advance(long now) {
        Stage next;
        switch (stage == null ? Stage.STOPPED : stage) {
            case PERMISSION: permissionDeferred = true; next = last.qrAvailable && !last.connected ? Stage.READY : last.connected && !onboarded ? Stage.SCREENS : Stage.IDLE; break;
            case GUIDE_MOVE: next = Stage.GUIDE_TAP; break;
            case GUIDE_TAP: next = Stage.SCREENS; break;
            case SCREENS: next = finish(); break;
            default: return false;
        }
        enter(next, now);
        return true;
    }

    /** Skips the whole guide from any guide stage. */
    public boolean skipGuide(long now) {
        if (stage != Stage.GUIDE_MOVE && stage != Stage.GUIDE_TAP && stage != Stage.SCREENS) return false;
        enter(finish(), now);
        return true;
    }

    /** Real input from the paired phone: moves advance the first guide step, a tap or scroll the second. */
    public boolean onInput(String action, long now) {
        if (stage == Stage.GUIDE_MOVE && "move".equals(action)) {
            if (++moves >= MOVES_TO_ADVANCE) { enter(Stage.GUIDE_TAP, now); return true; }
        } else if (stage == Stage.GUIDE_TAP && now - enteredAt >= TAP_GRACE_MS && ("click".equals(action) || "scroll".equals(action) || "focus_click".equals(action))) {
            enter(Stage.SCREENS, now); return true;
        }
        return false;
    }

    private void enter(Stage next, long now) { stage = next; enteredAt = now; moves = 0; }
}
