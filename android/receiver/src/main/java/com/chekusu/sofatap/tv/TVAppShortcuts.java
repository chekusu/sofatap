package com.chekusu.sofatap.tv;

import java.util.ArrayList;
import java.util.List;
import java.util.function.BooleanSupplier;

/** Fixed, local TV application shortcuts. No package, URL, component or Intent comes from the phone. */
public final class TVAppShortcuts {
    private record Target(String id, String packageName) { }
    private static final List<Target> TARGETS = List.of(
        new Target("youtube", "com.google.android.youtube.tv"),
        new Target("netflix", "com.netflix.ninja"));

    public interface Launcher {
        boolean available(String packageName);
        /** Recheck current immediately before the platform call; never retry a possibly dispatched launch. */
        boolean launch(String packageName, BooleanSupplier current);
    }
    public record Result(boolean ok, String code) { }
    private TVAppShortcuts() { }

    public static boolean supports(String app) { return target(app) != null; }

    public static List<String> availableApps(Launcher launcher) {
        List<String> result = new ArrayList<>();
        for (Target target : TARGETS) {
            try { if (launcher.available(target.packageName)) result.add(target.id); }
            catch (RuntimeException unavailable) { /* A removed/disabled app is not advertised. */ }
        }
        return result;
    }

    public static Result launch(String app, Launcher launcher, BooleanSupplier current) {
        Target target = target(app);
        if (target == null) return new Result(false, "unsupported_app");
        if (current == null || !current.getAsBoolean()) return new Result(false, "session_ended");
        try {
            if (!launcher.available(target.packageName)) return new Result(false, "app_not_installed");
            if (!current.getAsBoolean()) return new Result(false, "session_ended");
            boolean accepted = launcher.launch(target.packageName, current);
            if (!accepted) return new Result(false, current.getAsBoolean() ? "app_launch_failed" : "session_ended");
            // Acceptance is not proof the target rendered; the existing snapshot reports that boundary.
            return new Result(true, "ok");
        } catch (RuntimeException unavailable) { return new Result(false, "app_launch_failed"); }
    }

    private static Target target(String app) {
        for (Target target : TARGETS) if (target.id.equals(app)) return target;
        return null;
    }
}
