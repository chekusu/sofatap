package com.chekusu.sofatap.tv;

import org.junit.Test;
import static org.junit.Assert.*;

public final class SettingsFallbackTest {
    @Test public void addsSofatapWhenNothingIsEnabled() {
        assertEquals(SettingsFallback.ACCESSIBILITY_SERVICE, SettingsFallback.enabledServices(null));
        assertEquals(SettingsFallback.ACCESSIBILITY_SERVICE, SettingsFallback.enabledServices(""));
    }
    @Test public void keepsServicesTheTvAlreadyUses() {
        assertEquals("com.xgimi.duertts/.TtsService:" + SettingsFallback.ACCESSIBILITY_SERVICE,
            SettingsFallback.enabledServices("com.xgimi.duertts/.TtsService"));
    }
    @Test public void doesNotDuplicateSofatap() {
        String both = "a/.B:" + SettingsFallback.ACCESSIBILITY_SERVICE;
        assertEquals(both, SettingsFallback.enabledServices(both + ":a/.B"));
        assertEquals("com.chekusu.sofatap.tv/.input.SofatapAccessibilityService",
            SettingsFallback.enabledServices("com.chekusu.sofatap.tv/.input.SofatapAccessibilityService"));
    }
    @Test public void commandsNameOnlySofatapComponents() {
        String a11y = SettingsFallback.accessibilityCommands("x/.Y");
        assertTrue(a11y.contains("'x/.Y:" + SettingsFallback.ACCESSIBILITY_SERVICE + "'"));
        assertTrue(a11y.endsWith("accessibility_enabled 1"));
        assertEquals("adb shell ime enable com.chekusu.sofatap.tv/.SofatapInputMethodService\n"
            + "adb shell ime set com.chekusu.sofatap.tv/.SofatapInputMethodService", SettingsFallback.inputMethodCommands());
    }
}
