package com.chekusu.sofatap.controller;

import org.json.JSONObject;
import org.junit.Test;
import static org.junit.Assert.*;

public class ReceiverStatusTest {
    static JSONObject desktop() throws Exception {
        return new JSONObject().put("type", "hello").put("version", 1).put("name", "Test computer").put("platform", "windows")
            .put("inputAvailable", true).put("dryRun", false).put("inputStatus", "ready");
    }
    static JSONObject tv(boolean available, String navigation, String text) throws Exception {
        JSONObject caps = new JSONObject();
        for (String key : new String[]{"overlayCursor", "nodeClick", "scroll", "back", "home", "directionalFocus"}) caps.put(key, true);
        for (String key : new String[]{"text", "rawMouse", "rightClick", "drag"}) caps.put(key, false);
        JSONObject controls = new JSONObject().put("version", 1).put("navigationStatus", navigation).put("textStatus", text);
        if (text.equals("ready")) controls.put("editorEpoch", "A8E57498-A7D2-4A82-9D28-B34C830AC7DB");
        return new JSONObject().put("type", "hello").put("version", 1).put("name", "Test TV").put("platform", "androidtv")
            .put("inputAvailable", available).put("inputStatus", available ? "ready" : "accessibility_required")
            .put("capabilities", caps).put("tvControls", controls);
    }

    @Test public void desktopRequiresReadyAndHonorsDryRunAndFocusRevision() throws Exception {
        JSONObject message = desktop().put("textFocus", new JSONObject().put("state", "editable").put("revision", 2));
        ReceiverStatus state = ReceiverStatus.fromHello(message, false);
        assertTrue(state.ready); assertTrue(state.canDrag); assertTrue(state.canText); assertEquals("editable", state.focusState);
        assertEquals(2, state.focusRevision);
        ReceiverStatus dry = ReceiverStatus.fromHello(message.put("dryRun", true), false);
        assertFalse(dry.ready); assertFalse(dry.canClick); assertEquals("unknown", dry.focusState);
        assertEquals(-1, dry.focusRevision);
        ReceiverStatus invalidFocus = ReceiverStatus.fromHello(desktop().put("textFocus", new JSONObject().put("state", "editable").put("revision", true)), false);
        assertEquals("unknown", invalidFocus.focusState);
        assertEquals(-1, invalidFocus.focusRevision);
        assertEquals(-1, ReceiverStatus.fromHello(desktop(), false).focusRevision);
        ReceiverStatus next = state.withUpdate(desktop().put("textFocus", new JSONObject().put("state", "editable").put("revision", 3)));
        assertEquals(3, next.focusRevision);
        assertEquals(-1, state.withUpdate(desktop().put("textFocus", new JSONObject().put("state", "editable").put("revision", 2.5))).focusRevision);
    }

    @Test public void nativeTvPathsDoNotDependOnAccessibilityPermission() throws Exception {
        ReceiverStatus state = ReceiverStatus.fromHello(tv(false, "ready", "ready"), true);
        assertTrue(state.ready); assertTrue(state.canNavigate); assertTrue(state.canText); assertTrue(state.canBack); assertTrue(state.canHome);
        assertFalse(state.canMove); assertFalse(state.canClick); assertFalse(state.canScroll); assertFalse(state.canDrag); assertFalse(state.canRightClick);
        assertEquals("a8e57498-a7d2-4a82-9d28-b34c830ac7db", state.editorEpoch);
        assertEquals(-1, state.focusRevision);
    }

    @Test public void legacyTvDoesNotPromiseNativeNavigationOrText() throws Exception {
        JSONObject message = tv(true, "unsupported", "ime_required"); message.remove("tvControls");
        ReceiverStatus state = ReceiverStatus.fromHello(message, true);
        assertTrue(state.ready); assertTrue(state.canMove); assertTrue(state.canBack);
        assertFalse(state.canNavigate); assertFalse(state.canText); assertNull(state.editorEpoch);
    }

    @Test public void blockedTextAndLockedScreensNeverKeepOldCapabilities() throws Exception {
        ReceiverStatus state = ReceiverStatus.fromHello(tv(true, "ready", "ready"), true);
        ReceiverStatus noEditor = state.withUpdate(tv(true, "ready", "no_editor"));
        assertFalse(noEditor.canText); assertNull(noEditor.editorEpoch);
        ReceiverStatus locked = state.withUpdate(tv(false, "ready", "ready").put("inputStatus", "screen_locked"));
        assertFalse(locked.ready); assertFalse(locked.canNavigate); assertFalse(locked.canText); assertFalse(locked.canBack);
    }

    @Test public void rejectsMismatchedBooleansVersionsAndEditorEpochs() throws Exception {
        JSONObject[] bad = {tv(true, "ready", "ready").put("inputAvailable", "true"), tv(false, "ready", "ready").put("inputStatus", "ready"),
            tv(true, "ready", "ready").put("version", true), tv(true, "ready", "ready").put("platform", "windows"),
            tv(true, "ready", "ready").put("pairingToken", "short")};
        for (JSONObject value : bad) assertThrows(IllegalArgumentException.class, () -> ReceiverStatus.fromHello(value, true));
        JSONObject missing = tv(true, "ready", "ready"); missing.getJSONObject("tvControls").remove("editorEpoch");
        assertThrows(IllegalArgumentException.class, () -> ReceiverStatus.fromHello(missing, true));
        JSONObject malformed = tv(true, "ready", "ready"); malformed.getJSONObject("tvControls").put("editorEpoch", "1-1-1-1-1");
        assertThrows(IllegalArgumentException.class, () -> ReceiverStatus.fromHello(malformed, true));
        JSONObject added = tv(true, "ready", "ready"); added.getJSONObject("capabilities").put("rawMouse", true);
        assertThrows(IllegalArgumentException.class, () -> ReceiverStatus.fromHello(added, true));
    }

    @Test public void ordinaryAckRetainsStatusButPartialStatusFailsClosed() throws Exception {
        ReceiverStatus state = ReceiverStatus.fromHello(desktop(), false);
        assertSame(state, state.withUpdate(new JSONObject().put("type", "ack").put("ok", true)));
        assertThrows(IllegalArgumentException.class, () -> state.withUpdate(new JSONObject().put("inputAvailable", false)));
        assertFalse(state.withUpdate(desktop().put("inputStatus", "desktop_unavailable").put("inputAvailable", false)).ready);
    }

    @Test public void topLevelAppShortcutExtensionDoesNotBlockOrGrantNativeControls() throws Exception {
        JSONObject shortcuts = new JSONObject().put("schema", 1)
            .put("availableApps", new org.json.JSONArray().put("youtube").put("netflix"));
        ReceiverStatus state = ReceiverStatus.fromHello(tv(true, "pairing_required", "no_editor")
            .put("appShortcuts", shortcuts), true);
        assertTrue(state.ready); assertTrue(state.canMove); assertTrue(state.canBack);
        assertFalse(state.canNavigate); assertFalse(state.canText); assertNull(state.editorEpoch);
        assertSame(state, state.withUpdate(new JSONObject().put("type", "ack").put("ok", true)
            .put("appShortcuts", shortcuts)));
        ReceiverStatus revoked = state.withUpdate(tv(false, "pairing_required", "no_editor")
            .put("appShortcuts", shortcuts));
        assertFalse(revoked.ready); assertFalse(revoked.canMove); assertFalse(revoked.canBack);
        assertFalse(revoked.canNavigate); assertFalse(revoked.canText);
    }
}
