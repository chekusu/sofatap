package com.chekusu.sofatap.tv;

import java.util.ArrayList;
import java.util.List;

/**
 * Some China-market TVs and projectors (for example XGIMI on Android 11) ship a vendor
 * Settings app without Accessibility or keyboard pages, so the standard settings intents
 * resolve to nothing and the remote control cannot reach them. This builds the explicit
 * ADB commands the owner can run from a computer instead. Nothing here runs them.
 */
final class SettingsFallback {
    static final String ACCESSIBILITY_SERVICE = "com.chekusu.sofatap.tv/com.chekusu.sofatap.tv.input.SofatapAccessibilityService";
    static final String INPUT_METHOD = "com.chekusu.sofatap.tv/.SofatapInputMethodService";

    private SettingsFallback() { }

    /** Keeps every service that is already enabled and appends Sofatap's once. */
    static String enabledServices(String current) {
        List<String> services = new ArrayList<>();
        if (current != null) for (String part : current.split(":")) {
            String service = part.trim();
            if (!service.isEmpty() && !services.contains(service)) services.add(service);
        }
        boolean present = services.contains(ACCESSIBILITY_SERVICE)
            || services.contains("com.chekusu.sofatap.tv/.input.SofatapAccessibilityService");
        if (!present) services.add(ACCESSIBILITY_SERVICE);
        return String.join(":", services);
    }

    static String accessibilityCommands(String current) {
        return "adb shell settings put secure enabled_accessibility_services '" + enabledServices(current) + "'\n"
            + "adb shell settings put secure accessibility_enabled 1";
    }

    static String inputMethodCommands() {
        return "adb shell ime enable " + INPUT_METHOD + "\n"
            + "adb shell ime set " + INPUT_METHOD;
    }
}
