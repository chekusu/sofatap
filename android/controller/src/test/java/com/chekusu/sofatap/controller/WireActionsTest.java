package com.chekusu.sofatap.controller;

import org.json.JSONObject;
import org.junit.Test;
import java.util.UUID;
import static org.junit.Assert.*;

public class WireActionsTest {
    @Test public void desktopClicksDragAndShortcutsUseExistingContract() throws Exception {
        Pairing p = PairingTest.pairing(false);
        JSONObject right = WireActions.click(p, true);
        assertEquals("right", right.getString("button")); assertEquals("click", right.getString("type"));
        assertEquals(right.getString("id"), UUID.fromString(right.getString("id")).toString());
        assertNotEquals(right.getString("id"), WireActions.click(p, true).getString("id"));
        assertTrue(WireActions.button(p, true).getBoolean("down"));
        assertEquals("win", WireActions.key(p, "selectAll", "macos").getJSONArray("modifiers").getString(0));
        assertEquals("ctrl", WireActions.key(p, "a", "windows").getJSONArray("modifiers").getString(0));
        assertEquals(0, WireActions.key(p, "backspace", "windows").getJSONArray("modifiers").length());
    }

    @Test public void tvDirectionsAreNativeKeysAndPointerClickIsSeparate() throws Exception {
        Pairing p = PairingTest.pairing(true);
        assertEquals("remote_key", WireActions.key(p, "confirm", "androidtv").getString("type"));
        assertEquals("click", WireActions.click(p, false).getString("type"));
        assertFalse(WireActions.click(p, false).has("button"));
        assertThrows(IllegalArgumentException.class, () -> WireActions.click(p, true));
        assertThrows(IllegalArgumentException.class, () -> WireActions.button(p, true));
        assertThrows(IllegalArgumentException.class, () -> WireActions.key(p, "paste", "androidtv"));
        ReceiverStatus legacy = ReceiverStatus.fromHello(ReceiverStatusTest.tv(true, "unsupported", "ime_required"), true);
        assertEquals("key", WireActions.key(p, legacy, "back").getString("type"));
        assertThrows(IllegalArgumentException.class, () -> WireActions.key(p, legacy, "confirm"));
    }

    @Test public void scrollDirectionAndFiniteBoundsAreEnforced() throws Exception {
        assertEquals(-24, WireActions.scroll(PairingTest.pairing(false), -24).getDouble("dy"), 0);
        assertEquals(24, WireActions.scroll(PairingTest.pairing(true), -24).getDouble("dy"), 0);
        assertThrows(IllegalArgumentException.class, () -> WireActions.move(PairingTest.pairing(false), Double.NaN, 0));
        assertThrows(IllegalArgumentException.class, () -> WireActions.move(PairingTest.pairing(false), 501, 0));
        assertThrows(IllegalArgumentException.class, () -> WireActions.scroll(PairingTest.pairing(false), 1201));
    }

    @Test public void unicodeTextIsBoundToCurrentTvEditor() throws Exception {
        Pairing tv = PairingTest.pairing(true);
        ReceiverStatus state = ReceiverStatus.fromHello(ReceiverStatusTest.tv(false, "ready", "ready"), true);
        JSONObject message = WireActions.text(tv, state, "中文 日本語 emoji 👨‍👩‍👧‍👦");
        assertEquals("text_commit", message.getString("type")); assertEquals(state.editorEpoch, message.getString("editorEpoch"));
        assertEquals("text_backspace", WireActions.backspace(tv, state).getString("type"));
        assertEquals("text_action", WireActions.enter(tv, state).getString("type"));
        assertThrows(IllegalArgumentException.class, () -> WireActions.text(tv, state, "字".repeat(1366)));
        ReceiverStatus sensitive = ReceiverStatus.fromHello(ReceiverStatusTest.tv(true, "ready", "sensitive"), true);
        assertThrows(IllegalArgumentException.class, () -> WireActions.text(tv, sensitive, "private"));
        assertThrows(IllegalArgumentException.class, () -> WireActions.backspace(tv, sensitive));
    }

    @Test public void rejectsMalformedUnicodeAndOversizedDesktopPayload() throws Exception {
        Pairing p = PairingTest.pairing(false);
        ReceiverStatus state = ReceiverStatus.fromHello(ReceiverStatusTest.desktop(), false);
        assertEquals("text", WireActions.text(p, state, "new dictation 🛋️").getString("type"));
        for (String bad : new String[]{"\u0000", "\uD800", "\uDC00", "a".repeat(16001), "\u0001".repeat(16000)}) {
            assertThrows(IllegalArgumentException.class, () -> WireActions.text(p, state, bad));
        }
        assertEquals("backspace", WireActions.backspace(p, state).getString("key"));
        assertEquals("enter", WireActions.enter(p, state).getString("key"));
    }

    @Test public void pairingCodesAndKeepAliveHaveNarrowSchemas() throws Exception {
        assertEquals("ABCDEF", WireActions.remotePairCode("abcdef").getString("code"));
        assertThrows(IllegalArgumentException.class, () -> WireActions.remotePairCode("12345G"));
        assertEquals(2, WireActions.remotePairStart().length());
        assertEquals(2, WireActions.ping().length());
    }
}
