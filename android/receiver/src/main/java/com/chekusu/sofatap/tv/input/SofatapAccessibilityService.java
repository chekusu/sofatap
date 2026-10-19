package com.chekusu.sofatap.tv.input;

import android.accessibilityservice.AccessibilityService;
import android.app.KeyguardManager;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.content.res.Configuration;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Paint;
import android.graphics.PixelFormat;
import android.graphics.Point;
import android.graphics.Rect;
import android.os.Build;
import android.os.PowerManager;
import android.os.SystemClock;
import android.view.Display;
import android.view.Gravity;
import android.view.View;
import android.view.WindowManager;
import android.view.accessibility.AccessibilityEvent;
import android.view.accessibility.AccessibilityNodeInfo;
import android.view.accessibility.AccessibilityWindowInfo;
import java.util.ArrayList;
import java.util.List;
import org.json.JSONException;
import org.json.JSONObject;

/** A conditional node controller, not a source of injected mouse or touchscreen events. */
public final class SofatapAccessibilityService extends AccessibilityService {
    private static final int MAX_NODES = 2048;
    private static final int MAX_DEPTH = 64;
    private WindowManager windows;
    private CursorGeometry cursor;
    private CursorView overlay;
    private boolean overlayAttached;
    private boolean broadcastRegistered;
    private boolean wasReady;
    private final ScrollGate scrollGate = new ScrollGate();

    private final BroadcastReceiver screenReceiver = new BroadcastReceiver() {
        @Override public void onReceive(Context context, Intent intent) {
            if (Intent.ACTION_SCREEN_OFF.equals(intent.getAction())) {
                wasReady = false;
                InputBridge.interrupt();
            }
        }
    };

    @Override protected void onServiceConnected() {
        super.onServiceConnected();
        windows = (WindowManager) getSystemService(WINDOW_SERVICE);
        updateDisplaySize();
        InputBridge.attach(this);
        IntentFilter filter = new IntentFilter(Intent.ACTION_SCREEN_OFF);
        if (!broadcastRegistered) {
            if (Build.VERSION.SDK_INT >= 33) registerReceiver(screenReceiver, filter, RECEIVER_NOT_EXPORTED);
            else registerReceiver(screenReceiver, filter);
            broadcastRegistered = true;
        }
        wasReady = "ready".equals(availability());
    }

    @Override public void onAccessibilityEvent(AccessibilityEvent event) {
        // Deliberately do not inspect event text or keep node trees between commands.
        boolean ready = "ready".equals(availability());
        if (wasReady && !ready) InputBridge.interrupt();
        wasReady = ready;
    }

    @Override public void onInterrupt() { InputBridge.interrupt(); }

    @Override public boolean onUnbind(Intent intent) {
        InputBridge.detach(this);
        resetCursor();
        stopScreenObserver();
        return super.onUnbind(intent);
    }

    @Override public void onDestroy() {
        InputBridge.detach(this);
        resetCursor();
        stopScreenObserver();
        super.onDestroy();
    }

    private void stopScreenObserver() {
        if (!broadcastRegistered) return;
        unregisterReceiver(screenReceiver);
        broadcastRegistered = false;
    }

    @Override public void onConfigurationChanged(Configuration configuration) {
        super.onConfigurationChanged(configuration);
        InputBridge.interrupt();
        updateDisplaySize();
    }

    String availability() {
        PowerManager power = (PowerManager) getSystemService(POWER_SERVICE);
        KeyguardManager keyguard = (KeyguardManager) getSystemService(KEYGUARD_SERVICE);
        if (power == null || keyguard == null || windows == null || cursor == null) return "unavailable";
        if (!power.isInteractive() || keyguard.isKeyguardLocked() || keyguard.isDeviceLocked()) {
            return "screen_locked";
        }
        return "ready";
    }

    void addLocalStatusFields(JSONObject snapshot) {
        try {
            // A status frame also acknowledges native keys and IME input. It must not
            // wait for another app's accessibility tree: a slow video app used to delay
            // every successful native action here. Actual node input checks its target.
            snapshot.put("cursorVisible", overlayAttached);
            snapshot.put("touchscreenFeature", getPackageManager().hasSystemFeature("android.hardware.touchscreen"));
            snapshot.put("fakeTouchFeature", getPackageManager().hasSystemFeature("android.hardware.faketouch"));
            snapshot.put("requiresTouchscreen", false);
            if (cursor != null) {
                snapshot.put("displayWidth", cursor.width());
                snapshot.put("displayHeight", cursor.height());
            }
        } catch (RuntimeException | JSONException ignored) {
            // A probe must never expose exception text containing app data.
        }
    }

    JSONObject performInput(String action, double x, double y) {
        String status = availability();
        if (!"ready".equals(status)) {
            InputBridge.interrupt();
            return InputBridge.result(false, status);
        }
        if (action == null || !CursorGeometry.validDelta(x) || !CursorGeometry.validDelta(y)) {
            return InputBridge.result(false, "invalid_action");
        }
        try {
            switch (action) {
                case "move":
                    if (!cursor.move(x, y)) return InputBridge.result(false, "invalid_delta");
                    if (!showCursor()) return InputBridge.result(false, "overlay_unavailable");
                    return InputBridge.object("ok", true, "code", "cursor_moved", "x", cursor.x(), "y", cursor.y());
                case "click":
                    return pointAction(false, 0, 0);
                case "scroll":
                    if (x == 0 && y == 0) return InputBridge.result(true, "no_change");
                    ScrollGate.Step step = scrollGate.offer(x, y, SystemClock.elapsedRealtime());
                    if (step == null) return InputBridge.result(true, "scroll_buffered");
                    return pointAction(true, step.x, step.y);
                case "focus_up": return focusAction(View.FOCUS_UP, false);
                case "focus_down": return focusAction(View.FOCUS_DOWN, false);
                case "focus_left": return focusAction(View.FOCUS_LEFT, false);
                case "focus_right": return focusAction(View.FOCUS_RIGHT, false);
                case "focus_click": return focusAction(0, true);
                case "back": return globalAction(GLOBAL_ACTION_BACK);
                case "home": return globalAction(GLOBAL_ACTION_HOME);
                default: return InputBridge.result(false, "unsupported_action");
            }
        } catch (RuntimeException ignored) {
            resetCursor();
            return InputBridge.result(false, "input_unavailable");
        }
    }

    private JSONObject globalAction(int action) {
        // Back/Home cannot grant permissions and are useful to leave an unsupported application.
        return accepted(performGlobalAction(action));
    }

    private JSONObject pointAction(boolean scroll, double dx, double dy) {
        if (!showCursor()) return InputBridge.result(false, "overlay_unavailable");
        AccessibilityNodeInfo root = getRootInActiveWindow();
        if (root == null) return InputBridge.result(false, "window_unavailable");
        ArrayList<AccessibilityNodeInfo> nodes = new ArrayList<>();
        ArrayList<NodeHitPolicy.Region> regions = new ArrayList<>();
        ArrayList<Integer> actions = new ArrayList<>();
        try {
            if (!root.refresh() || !safeWindow(root)) return InputBridge.result(false, "protected_window");
            if (!collect(root, 0, -1, false, nodes, regions, actions, scroll, dx, dy)) {
                return InputBridge.result(false, "window_too_complex");
            }
            int choice = NodeHitPolicy.pick(regions, cursor.x(), cursor.y());
            if (choice == NodeHitPolicy.BLOCKED) return InputBridge.result(false, "protected_target");
            if (choice == NodeHitPolicy.AMBIGUOUS) return InputBridge.result(false, "ambiguous_target");
            if (choice == NodeHitPolicy.NONE) return InputBridge.result(false, "no_accessible_target");
            AccessibilityNodeInfo node = nodes.get(choice);
            int action = actions.get(choice);
            if (!node.refresh() || !safeNode(node) || !hasAction(node, action)
                    || !stillActive(root.getWindowId()) || !hasSafeAncestors(node)) {
                return InputBridge.result(false, "target_changed");
            }
            Rect bounds = new Rect();
            node.getBoundsInScreen(bounds);
            if (!bounds.contains((int) cursor.x(), (int) cursor.y())) {
                return InputBridge.result(false, "target_changed");
            }
            return accepted(node.performAction(action));
        } finally {
            for (AccessibilityNodeInfo node : nodes) recycle(node);
            recycle(root);
        }
    }

    private boolean collect(AccessibilityNodeInfo node, int depth, int parent, boolean blockedAncestor,
                            List<AccessibilityNodeInfo> nodes, List<NodeHitPolicy.Region> regions,
                            List<Integer> actions, boolean scroll, double dx, double dy) {
        if (depth > MAX_DEPTH || nodes.size() >= MAX_NODES) return false;
        if (!node.isVisibleToUser()) return true;
        boolean blocked = blockedAncestor || sensitive(node);
        Rect bounds = new Rect();
        node.getBoundsInScreen(bounds);
        int action = scroll ? scrollAction(node, dx, dy) : AccessibilityNodeInfo.ACTION_CLICK;
        boolean actionable = node.isEnabled() && !blocked && hasAction(node, action);
        int index = nodes.size();
        nodes.add(AccessibilityNodeInfo.obtain(node));
        actions.add(action);
        regions.add(new NodeHitPolicy.Region(bounds.left, bounds.top, bounds.right, bounds.bottom,
                depth, parent, actionable, blocked));
        int count = node.getChildCount();
        if (count > MAX_NODES) return false;
        for (int i = 0; i < count; i++) {
            AccessibilityNodeInfo child = node.getChild(i);
            if (child == null) continue;
            try {
                if (!collect(child, depth + 1, index, blocked, nodes, regions, actions, scroll, dx, dy)) return false;
            } finally { recycle(child); }
        }
        return true;
    }

    private int scrollAction(AccessibilityNodeInfo node, double dx, double dy) {
        boolean horizontal = Math.abs(dx) > Math.abs(dy);
        int specific = horizontal
                ? (dx > 0 ? AccessibilityNodeInfo.AccessibilityAction.ACTION_SCROLL_RIGHT.getId()
                          : AccessibilityNodeInfo.AccessibilityAction.ACTION_SCROLL_LEFT.getId())
                : (dy > 0 ? AccessibilityNodeInfo.AccessibilityAction.ACTION_SCROLL_DOWN.getId()
                          : AccessibilityNodeInfo.AccessibilityAction.ACTION_SCROLL_UP.getId());
        if (hasAction(node, specific)) return specific;
        // Generic forward/backward is not assumed to be horizontal scrolling.
        if (horizontal) return specific;
        return dy > 0 ? AccessibilityNodeInfo.ACTION_SCROLL_FORWARD : AccessibilityNodeInfo.ACTION_SCROLL_BACKWARD;
    }

    private JSONObject focusAction(int direction, boolean click) {
        AccessibilityNodeInfo root = getRootInActiveWindow();
        AccessibilityNodeInfo focused = null;
        AccessibilityNodeInfo target = null;
        try {
            if (root == null) return InputBridge.result(false, "window_unavailable");
            if (!root.refresh() || !safeWindow(root)) return InputBridge.result(false, "protected_window");
            focused = root.findFocus(AccessibilityNodeInfo.FOCUS_INPUT);
            if (focused == null) focused = root.findFocus(AccessibilityNodeInfo.FOCUS_ACCESSIBILITY);
            if (click) {
                if (focused == null) return InputBridge.result(false, "no_focused_target");
                target = AccessibilityNodeInfo.obtain(focused);
            } else {
                target = (focused != null ? focused : root).focusSearch(direction);
            }
            if (target == null) return InputBridge.result(false, "no_focus_target");
            int action = click ? AccessibilityNodeInfo.ACTION_CLICK : AccessibilityNodeInfo.ACTION_FOCUS;
            if (!target.refresh() || !safeNode(target) || !hasSafeAncestors(target)) {
                return InputBridge.result(false, "protected_target");
            }
            if (target.getWindowId() != root.getWindowId() || !stillActive(root.getWindowId())) {
                return InputBridge.result(false, "target_changed");
            }
            if (!hasAction(target, action)) return InputBridge.result(false, "action_unavailable");
            return accepted(target.performAction(action));
        } finally {
            recycle(target);
            recycle(focused);
            recycle(root);
        }
    }

    private boolean stillActive(int windowId) {
        if (!"ready".equals(availability())) return false;
        AccessibilityNodeInfo fresh = getRootInActiveWindow();
        try { return fresh != null && fresh.getWindowId() == windowId && fresh.refresh() && safeWindow(fresh); }
        finally { recycle(fresh); }
    }

    private boolean safeWindow(AccessibilityNodeInfo root) {
        CharSequence packageName = root.getPackageName();
        if (packageName == null) return false;
        String name = packageName.toString();
        if (name.equals("com.android.systemui") || name.endsWith(".permissioncontroller")
                || name.endsWith(".packageinstaller")) return false;
        AccessibilityWindowInfo window = root.getWindow();
        if (window == null) return false;
        try {
            if (window.getType() != AccessibilityWindowInfo.TYPE_APPLICATION) return false;
            return Build.VERSION.SDK_INT < 30 || window.getDisplayId() == Display.DEFAULT_DISPLAY;
        } finally { window.recycle(); }
    }

    private boolean safeNode(AccessibilityNodeInfo node) {
        return node.isVisibleToUser() && node.isEnabled() && !sensitive(node);
    }

    private boolean sensitive(AccessibilityNodeInfo node) {
        if (node.isPassword()) return true;
        if (Build.VERSION.SDK_INT >= 34 && node.isAccessibilityDataSensitive()) return true;
        String id = node.getViewIdResourceName();
        return id != null && id.startsWith(getPackageName() + ":id/")
                && (id.endsWith("/accessibility_setup") || id.endsWith("/pairing_approve"));
    }

    private boolean hasSafeAncestors(AccessibilityNodeInfo target) {
        AccessibilityNodeInfo current = AccessibilityNodeInfo.obtain(target);
        try {
            for (int depth = 0; depth <= MAX_DEPTH; depth++) {
                if (!current.refresh() || sensitive(current)) return false;
                AccessibilityNodeInfo parent = current.getParent();
                if (parent == null) return true;
                recycle(current);
                current = parent;
            }
            return false;
        } finally { recycle(current); }
    }

    private static boolean hasAction(AccessibilityNodeInfo node, int action) {
        for (AccessibilityNodeInfo.AccessibilityAction item : node.getActionList()) {
            if (item.getId() == action) return true;
        }
        return false;
    }

    private static JSONObject accepted(boolean value) {
        return InputBridge.result(value, value ? "framework_accepted" : "action_rejected");
    }

    private void updateDisplaySize() {
        if (windows == null) return;
        Point size = new Point();
        windows.getDefaultDisplay().getRealSize(size);
        if (size.x > 0 && size.y > 0) cursor = new CursorGeometry(size.x, size.y);
    }

    private boolean showCursor() {
        if (overlay == null) overlay = new CursorView(this);
        if (!overlayAttached) {
            WindowManager.LayoutParams layout = new WindowManager.LayoutParams(
                    WindowManager.LayoutParams.MATCH_PARENT, WindowManager.LayoutParams.MATCH_PARENT,
                    WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY,
                    WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE | WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE
                            | WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
                    PixelFormat.TRANSLUCENT);
            layout.gravity = Gravity.TOP | Gravity.LEFT;
            layout.setTitle("Sofatap cursor");
            try {
                windows.addView(overlay, layout);
                overlayAttached = true;
            } catch (RuntimeException ignored) { return false; }
        }
        overlay.invalidate();
        return true;
    }

    void resetCursor() {
        scrollGate.reset();
        if (overlayAttached && windows != null && overlay != null) {
            try { windows.removeViewImmediate(overlay); } catch (RuntimeException ignored) {}
        }
        overlayAttached = false;
        overlay = null;
        if (cursor != null) cursor.reset();
    }

    @SuppressWarnings("deprecation")
    private static void recycle(AccessibilityNodeInfo node) { if (node != null) node.recycle(); }

    private final class CursorView extends View {
        private final Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG);
        CursorView(Context context) {
            super(context);
            setImportantForAccessibility(IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS);
            setFocusable(false);
            setClickable(false);
        }
        @Override protected void onDraw(Canvas canvas) {
            if (cursor == null) return;
            float radius = 7 * getResources().getDisplayMetrics().density;
            paint.setStyle(Paint.Style.FILL);
            paint.setColor(Color.rgb(159, 233, 199));
            canvas.drawCircle((float) cursor.x(), (float) cursor.y(), radius, paint);
            paint.setStyle(Paint.Style.STROKE);
            paint.setStrokeWidth(2 * getResources().getDisplayMetrics().density);
            paint.setColor(Color.rgb(15, 30, 31));
            canvas.drawCircle((float) cursor.x(), (float) cursor.y(), radius, paint);
        }
    }
}
