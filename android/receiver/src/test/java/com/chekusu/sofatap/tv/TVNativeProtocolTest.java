package com.chekusu.sofatap.tv;

import com.chekusu.sofatap.tv.input.ImeSession;
import java.util.Locale;
import java.util.function.BooleanSupplier;
import org.junit.Test;
import org.json.JSONObject;
import static org.junit.Assert.*;

public class TVNativeProtocolTest {
    private static final String ID = "123e4567-e89b-12d3-a456-426614174000";
    private JSONObject base(String type) throws Exception { return new JSONObject().put("id", ID).put("type", type); }
    @Test public void trueRemoteKeysHaveAnExplicitNamespaceSeparateFromNodeFocus() throws Exception {
        for (String key : new String[]{"up", "down", "left", "right", "confirm", "back", "home"}) {
            TVProtocol.Action action = TVProtocol.parse(base("remote_key").put("key", key).toString());
            assertTrue(action.extended()); assertEquals(key, action.key());
        }
        assertFalse(TVProtocol.parse(base("key").put("key", "confirm").toString()).extended());
        assertThrows(Exception.class, () -> TVProtocol.parse(base("remote_key").put("key", "power").toString()));
    }
    @Test public void pairingOnlyAcceptsSixHexDigitsAndNoHostOrPort() throws Exception {
        assertTrue(TVProtocol.parse(base("remote_pair_start").toString()).extended());
        assertEquals("Ab12F0", TVProtocol.parse(base("remote_pair_code").put("code", "Ab12F0").toString()).code());
        for (String code : new String[]{"12345", "1234567", "12345G", " 12345", "１２３４５６"})
            assertThrows(Exception.class, () -> TVProtocol.parse(base("remote_pair_code").put("code", code).toString()));
        assertThrows(Exception.class, () -> TVProtocol.parse(base("remote_pair_start").put("host", "127.0.0.1").toString()));
    }
    @Test public void textRequiresCanonicalEpochAndValidBoundedUnicode() throws Exception {
        String text = "中文 日本語 😺\n";
        assertEquals(text, TVProtocol.parse(base("text_commit").put("editorEpoch", ID).put("text", text).toString()).text());
        assertEquals(4096, TVProtocol.parse(base("text_commit").put("editorEpoch", ID).put("text", "a".repeat(4096)).toString()).text().length());
        for (String invalid : new String[]{"a".repeat(4097), "😺".repeat(1025), "\uD800", "\uDC00", "a\0b"})
            assertThrows(Exception.class, () -> TVProtocol.parse(base("text_commit").put("editorEpoch", ID).put("text", invalid).toString()));
        assertThrows(Exception.class, () -> TVProtocol.parse(base("text_commit").put("editorEpoch", "1-1-1-1-1").put("text", "x").toString()));
    }
    @Test public void textDeletionAndActionCannotSelectOtherEditorsOrSupplyArbitraryActions() throws Exception {
        for (String type : new String[]{"text_backspace", "text_action"}) {
            assertEquals(ID, TVProtocol.parse(base(type).put("editorEpoch", ID).toString()).editorEpoch());
            assertThrows(Exception.class, () -> TVProtocol.parse(base(type).put("editorEpoch", ID).put("action", "shell").toString()));
            assertThrows(Exception.class, () -> TVProtocol.parse(base(type).toString()));
        }
    }

    @Test public void textCommandsAcceptTheSameUuidAcrossJavaAndSwiftWireCase() throws Exception {
        for (String type : new String[]{"text_commit", "text_backspace", "text_action"}) {
            for (int spelling = 0; spelling < 3; spelling++) {
                ImeSession session = new ImeSession();
                RecordingEditor editor = new RecordingEditor();
                String epoch = startWithHexLetters(session, editor);
                String wireEpoch = switch (spelling) {
                    case 0 -> epoch;
                    case 1 -> epoch.toUpperCase(Locale.ROOT); // Foundation UUID.uuidString
                    default -> mixedCase(epoch);
                };
                TVProtocol.Action action = parseText(type, wireEpoch);
                ImeSession.Result result = session.apply(action.type(), action.editorEpoch(), action.text(), () -> true);
                assertTrue(type + " spelling " + spelling + " was rejected as " + result.code(), result.ok());
                assertEquals(1, editor.calls);
                assertEquals(type.equals("text_commit") ? "中文 😺" : null, editor.committed);
                assertEquals(type.equals("text_backspace") ? 1 : 0, editor.deletions);
                assertEquals(type.equals("text_action") ? 6 : 0, editor.action);
            }
        }
    }

    @Test public void uuidCaseNormalizationNeverRevivesDifferentOrExpiredEditors() throws Exception {
        ImeSession session = new ImeSession();
        RecordingEditor editor = new RecordingEditor();
        String oldEpoch = startWithHexLetters(session, editor);
        for (String type : new String[]{"text_commit", "text_backspace", "text_action"}) {
            TVProtocol.Action different = parseText(type, ID.toUpperCase(Locale.ROOT));
            assertEquals("stale_editor", apply(session, different, () -> true).code());
            assertEquals(0, editor.calls);
        }
        session.controllerDisconnected();
        assertNotEquals(oldEpoch, session.epoch());
        for (String type : new String[]{"text_commit", "text_backspace", "text_action"}) {
            TVProtocol.Action old = parseText(type, oldEpoch.toUpperCase(Locale.ROOT));
            assertEquals("stale_editor", apply(session, old, () -> true).code());
            TVProtocol.Action current = parseText(type, mixedCase(session.epoch()));
            assertEquals("session_expired", apply(session, current, () -> false).code());
            assertEquals("session_expired", apply(session, current, null).code());
            assertEquals(0, editor.calls);
        }
        TVProtocol.Action current = parseText("text_commit", session.epoch().toUpperCase(Locale.ROOT));
        assertTrue(apply(session, current, () -> true).ok());
        assertEquals(1, editor.calls);
        session.start(editor, false, 3, 3, 6);
        assertEquals("stale_editor", apply(session, current, () -> true).code());
        assertEquals(1, editor.calls);
    }

    @Test public void uuidCaseNormalizationDoesNotRelaxCanonicalStructure() throws Exception {
        for (String type : new String[]{"text_commit", "text_backspace", "text_action"}) {
            for (String invalid : new String[]{"1-1-1-1-1", " " + ID, ID + " ", "{" + ID + "}",
                    ID.replace("-", ""), ID.replace('a', 'g'), "+" + ID, ID.replace('1', '１')}) {
                assertThrows(type + " accepted malformed epoch " + invalid, Exception.class, () -> parseText(type, invalid));
            }
        }
    }

    private TVProtocol.Action parseText(String type, String epoch) throws Exception {
        JSONObject object = base(type).put("editorEpoch", epoch);
        if (type.equals("text_commit")) object.put("text", "中文 😺");
        return TVProtocol.parse(object.toString());
    }
    private static ImeSession.Result apply(ImeSession session, TVProtocol.Action action, BooleanSupplier current) {
        return session.apply(action.type(), action.editorEpoch(), action.text(), current);
    }
    private static String startWithHexLetters(ImeSession session, RecordingEditor editor) {
        // Real Java-generated epochs, with two letters so the three wire spellings differ.
        do { session.start(editor, false, 3, 3, 6); }
        while (session.epoch().chars().filter(c -> c >= 'a' && c <= 'f').count() < 2);
        return session.epoch();
    }
    private static String mixedCase(String epoch) {
        for (int i = 0; i < epoch.length(); i++) {
            char c = epoch.charAt(i);
            if (c >= 'a' && c <= 'f') return epoch.substring(0, i) + Character.toUpperCase(c) + epoch.substring(i + 1);
        }
        return epoch;
    }
    private static final class RecordingEditor implements ImeSession.Editor {
        int calls, deletions, action;
        String committed;
        @Override public boolean commit(String text) { calls++; committed = text; return true; }
        @Override public boolean finishComposing() { calls++; return true; }
        @Override public boolean deleteCodePointBeforeCursor() { calls++; deletions++; return true; }
        @Override public boolean action(int value) { calls++; action = value; return true; }
    }
}
