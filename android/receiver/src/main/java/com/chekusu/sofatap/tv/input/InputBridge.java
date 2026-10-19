package com.chekusu.sofatap.tv.input;

import android.content.Context;
import android.os.Looper;
import com.chekusu.sofatap.tv.TVAppShortcuts;
import java.util.List;
import java.util.function.BooleanSupplier;
import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

/**
 * Main-thread entry point for an already authenticated, explicitly paired controller.
 * Transport owns authentication and ordered delivery. This class never enables accessibility.
 */
public final class InputBridge {
    private static SofatapAccessibilityService service;
    private static Runnable interruptionListener;

    private InputBridge() {}

    public static JSONObject snapshot(Context context) {
        requireMainThread();
        String state = service == null ? "accessibility_required" : service.availability();
        boolean available = "ready".equals(state);
        JSONObject capabilities = object("overlayCursor", available, "nodeClick", available,
                "scroll", available, "back", available, "home", available,
                "directionalFocus", available, "text", false, "rawMouse", false,
                "rightClick", false, "drag", false);
        JSONObject result = object("inputAvailable", available, "inputStatus", state,
                "capabilities", capabilities, "pointerMode", "accessibility_nodes",
                "actionResultMeaning", "framework_accepted_not_verified",
                "hardwareQualified", false, "defaultDisplayOnly", true);
        if (service != null) service.addLocalStatusFields(result);
        return result;
    }

    public static JSONObject appShortcuts() {
        requireMainThread();
        List<String> available = service != null && "ready".equals(service.availability())
            ? TVAppShortcuts.availableApps(new TVAppLauncher(service)) : List.of();
        return object("schema", 1, "availableApps", new JSONArray(available));
    }

    public static JSONObject launchApp(String app, BooleanSupplier current) {
        requireMainThread();
        if (current == null || !current.getAsBoolean()) return result(false, "session_ended");
        if (service == null) return result(false, "accessibility_required");
        if (!"ready".equals(service.availability())) return result(false, "protected_window");
        SofatapAccessibilityService target = service;
        TVAppShortcuts.Result launched = TVAppShortcuts.launch(app, new TVAppLauncher(target),
            () -> current.getAsBoolean() && service == target && "ready".equals(target.availability()));
        return result(launched.ok(), launched.code());
    }

    public static JSONObject perform(Context context, String action, double x, double y) {
        requireMainThread();
        if (service == null) return result(false, "accessibility_required");
        return service.performInput(action, x, y);
    }

    /** End control immediately; no cursor state or queued action survives a disconnect. */
    public static void disconnect() {
        requireMainThread();
        if (service != null) service.resetCursor();
    }

    /** Called when screen locks, powers off, or the accessibility service is interrupted/stopped. */
    public static void setInterruptionListener(Runnable listener) {
        requireMainThread();
        interruptionListener = listener;
    }

    static void attach(SofatapAccessibilityService instance) {
        requireMainThread();
        if (service != null && service != instance) interrupt();
        service = instance;
    }

    static void detach(SofatapAccessibilityService instance) {
        requireMainThread();
        if (service != instance) return;
        interrupt();
        service = null;
    }

    static void interrupt() {
        requireMainThread();
        if (service != null) service.resetCursor();
        if (interruptionListener != null) interruptionListener.run();
    }

    static JSONObject result(boolean ok, String code) {
        return object("ok", ok, "code", code);
    }

    static JSONObject object(Object... values) {
        JSONObject result = new JSONObject();
        try {
            for (int i = 0; i < values.length; i += 2) result.put((String) values[i], values[i + 1]);
        } catch (JSONException exception) {
            throw new IllegalArgumentException("Invalid JSON field", exception);
        }
        return result;
    }

    static void requireMainThread() {
        if (Looper.myLooper() != Looper.getMainLooper()) {
            throw new IllegalStateException("InputBridge requires the main thread");
        }
    }
}
