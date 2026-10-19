package com.chekusu.sofatap.tv;

import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.function.BooleanSupplier;
import org.junit.Test;
import static org.junit.Assert.*;

public final class TVAppShortcutsTest {
    private static final class Launcher implements TVAppShortcuts.Launcher {
        final List<String> checked = new ArrayList<>(), opened = new ArrayList<>();
        boolean installed = true, accept = true, fail;
        Runnable onResolve = () -> { }, beforeLaunch = () -> { };
        public boolean available(String packageName) {
            checked.add(packageName); onResolve.run(); return installed;
        }
        public boolean launch(String packageName, BooleanSupplier current) {
            beforeLaunch.run();
            if (!current.getAsBoolean()) return false;
            opened.add(packageName);
            if (fail) throw new IllegalStateException("fixture");
            return accept;
        }
    }
    @Test public void onlyFixedTvPackagesCanReachThePlatform() {
        Launcher launcher = new Launcher();
        assertEquals(List.of("youtube", "netflix"), TVAppShortcuts.availableApps(launcher));
        assertEquals(List.of("com.google.android.youtube.tv", "com.netflix.ninja"), launcher.checked);
        for (String app : new String[]{"youtube", "netflix"}) assertTrue(TVAppShortcuts.launch(app, launcher, () -> true).ok());
        assertEquals(List.of("com.google.android.youtube.tv", "com.netflix.ninja"), launcher.opened);
        int checks = launcher.checked.size();
        for (String invalid : new String[]{null, "", "com.android.settings", "netflix?url=evil", "intent://anything"})
            assertEquals("unsupported_app", TVAppShortcuts.launch(invalid, launcher, () -> true).code());
        assertEquals(checks, launcher.checked.size()); assertEquals(2, launcher.opened.size());
    }
    @Test public void MissingAppsAreNotAdvertisedAndCannotLaunch() {
        Launcher launcher = new Launcher(); launcher.installed = false;
        assertTrue(TVAppShortcuts.availableApps(launcher).isEmpty());
        assertEquals("app_not_installed", TVAppShortcuts.launch("youtube", launcher, () -> true).code());
        assertTrue(launcher.opened.isEmpty());
    }
    @Test public void expiredSessionCannotResolveOrLaunch() {
        Launcher launcher = new Launcher();
        assertEquals("session_ended", TVAppShortcuts.launch("youtube", launcher, () -> false).code());
        assertEquals("session_ended", TVAppShortcuts.launch("netflix", launcher, null).code());
        assertTrue(launcher.checked.isEmpty()); assertTrue(launcher.opened.isEmpty());
    }
    @Test public void disconnectDuringResolutionOrImmediatelyBeforeLaunchIsNotReplayed() {
        Launcher launcher = new Launcher(); AtomicBoolean current = new AtomicBoolean(true);
        launcher.onResolve = () -> current.set(false);
        assertEquals("session_ended", TVAppShortcuts.launch("youtube", launcher, current::get).code());
        assertTrue(launcher.opened.isEmpty());
        launcher.onResolve = () -> { }; current.set(true); launcher.beforeLaunch = () -> current.set(false);
        assertEquals("session_ended", TVAppShortcuts.launch("netflix", launcher, current::get).code());
        assertTrue(launcher.opened.isEmpty());
    }
    @Test public void platformFailureIsReportedAndNeverRetried() {
        Launcher launcher = new Launcher(); launcher.fail = true;
        assertEquals("app_launch_failed", TVAppShortcuts.launch("youtube", launcher, () -> true).code());
        assertEquals(1, launcher.opened.size());
        launcher.fail = false; launcher.accept = false;
        assertEquals("app_launch_failed", TVAppShortcuts.launch("netflix", launcher, () -> true).code());
        assertEquals(2, launcher.opened.size());
    }
}
