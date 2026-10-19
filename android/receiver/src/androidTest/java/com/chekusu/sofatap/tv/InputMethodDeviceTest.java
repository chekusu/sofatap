package com.chekusu.sofatap.tv;

import android.app.Instrumentation;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.content.pm.ServiceInfo;
import android.os.Build;
import android.text.InputType;
import android.view.inputmethod.EditorInfo;
import android.view.inputmethod.InputConnection;
import androidx.test.ext.junit.runners.AndroidJUnit4;
import androidx.test.platform.app.InstrumentationRegistry;
import com.chekusu.sofatap.tv.input.ImeSession;
import java.util.concurrent.atomic.AtomicReference;
import java.util.Locale;
import java.util.UUID;
import org.json.JSONObject;
import org.junit.After;
import org.junit.Assume;
import org.junit.Before;
import org.junit.Test;
import org.junit.runner.RunWith;
import static org.junit.Assert.*;

/** Real EditText/InputConnection contract, without changing the selected system IME or using ADB. */
@RunWith(AndroidJUnit4.class)
public final class InputMethodDeviceTest {
    private Instrumentation instrumentation;
    private Context context;
    private ImeFixtureActivity activity;
    private final ImeSession session = new ImeSession();
    private InputConnection connection;

    @Before public void disposableEmulatorOnly() {
        instrumentation = InstrumentationRegistry.getInstrumentation();
        Assume.assumeTrue("Only an explicitly opted-in disposable emulator is allowed",
            "yes".equals(InstrumentationRegistry.getArguments().getString("disposableEmulator"))
                && (Build.FINGERPRINT.contains("generic") || Build.MODEL.contains("sdk")));
        context = instrumentation.getTargetContext();
        activity = (ImeFixtureActivity) instrumentation.startActivitySync(
            new Intent(context, ImeFixtureActivity.class).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
    }

    @After public void closeOwnedFixture() throws Exception {
        if (activity != null) main(() -> { session.invalidate(); activity.finish(); });
    }

    @Test public void manifestExportsOnlyTheSystemProtectedInputMethodBinding() throws Exception {
        ServiceInfo info = context.getPackageManager().getServiceInfo(
            new ComponentName(context, SofatapInputMethodService.class), PackageManager.GET_META_DATA);
        assertTrue(info.exported);
        assertEquals("android.permission.BIND_INPUT_METHOD", info.permission);
        assertTrue(info.metaData.getInt("android.view.im") != 0);
    }

    @Test public void unicodeCommitAndCodePointBackspaceUseRealEditTextConnection() throws Exception {
        main(() -> {
            String epoch = start("沙发 日本語", false);
            assertTrue(apply("text_commit", epoch, "🛋").ok());
            assertEquals("沙发 日本語🛋", activity.editor.getText().toString());
            selectionChanged();
            assertTrue(apply("text_backspace", epoch, null).ok());
            assertEquals("沙发 日本語", activity.editor.getText().toString());
        });
    }

    @Test public void uppercaseWireEpochReachesRealEditorButOldEpochStillFails() throws Exception {
        main(() -> {
            String epoch = start("", false);
            // Foundation UUID.uuidString sends uppercase while Java advertises lowercase.
            assertTrue(applyWire("text_commit", epoch.toUpperCase(Locale.ROOT), "沙发🛋").ok());
            assertEquals("沙发🛋", activity.editor.getText().toString());
            selectionChanged();
            assertTrue(applyWire("text_backspace", epoch.toUpperCase(Locale.ROOT), null).ok());
            assertEquals("沙发", activity.editor.getText().toString());
            int[] action = {-1};
            activity.editor.setOnEditorActionListener((view, id, event) -> { action[0] = id; return true; });
            assertTrue(applyWire("text_action", epoch.toUpperCase(Locale.ROOT), null).ok());
            assertEquals(EditorInfo.IME_ACTION_SEARCH, action[0]);
            start("next editor", false);
            assertEquals("stale_editor", applyWire("text_commit", epoch.toUpperCase(Locale.ROOT), "late").code());
            assertEquals("next editor", activity.editor.getText().toString());
        });
    }

    @Test public void selectedDeletionDoesNotDeleteAnUnrelatedComposingRegion() throws Exception {
        main(() -> {
            String epoch = start("abc DEF", false);
            assertTrue(connection.setComposingRegion(0, 3));
            activity.editor.setSelection(4, 7);
            selectionChanged();
            assertTrue(apply("text_backspace", epoch, null).ok());
            assertEquals("abc ", activity.editor.getText().toString());
        });
    }

    @Test public void rapidBackspaceAndStartOfTextNeedNoIntermediateSelectionCallback() throws Exception {
        main(() -> {
            String epoch = start("A🛋", false);
            assertTrue(apply("text_backspace", epoch, null).ok());
            assertEquals("A", activity.editor.getText().toString());
            assertTrue(apply("text_backspace", epoch, null).ok());
            assertEquals("", activity.editor.getText().toString());
            assertTrue(apply("text_backspace", epoch, null).ok());
            selectionChanged();
            assertTrue(apply("text_backspace", epoch, null).ok());
            assertTrue(apply("text_commit", epoch, "next").ok());
            assertEquals("next", activity.editor.getText().toString());
        });
    }

    @Test public void disconnectedControllerMustGetNewEpochWithoutRefocusingEditor() throws Exception {
        main(() -> {
            String oldEpoch = start("kept", false);
            session.controllerDisconnected();
            assertEquals("stale_editor", apply("text_commit", oldEpoch, "late").code());
            assertEquals("kept", activity.editor.getText().toString());
            assertTrue(apply("text_commit", session.epoch(), " current").ok());
            assertEquals("kept current", activity.editor.getText().toString());
        });
    }

    @Test public void restartDisconnectAndSensitiveFieldsCannotReceiveStaleText() throws Exception {
        main(() -> {
            String oldEpoch = start("first", false);
            String nextEpoch = start("next", false);
            assertNotEquals(oldEpoch, nextEpoch);
            assertEquals("stale_editor", apply("text_commit", oldEpoch, "late").code());
            assertEquals("next", activity.editor.getText().toString());
            session.invalidate();
            assertEquals("no_editor", apply("text_commit", nextEpoch, "late").code());
            start("protected", true);
            assertNull(session.epoch());
            assertEquals("sensitive", apply("text_commit", nextEpoch, "late").code());
            assertEquals("protected", activity.editor.getText().toString());
        });
    }

    @Test public void editorActionUsesOnlyTheCurrentEditorAction() throws Exception {
        main(() -> {
            int[] action = {-1};
            activity.editor.setOnEditorActionListener((view, id, event) -> { action[0] = id; return true; });
            String epoch = start("query", false);
            assertTrue(apply("text_action", epoch, null).ok());
            assertEquals(EditorInfo.IME_ACTION_SEARCH, action[0]);
        });
    }

    @Test public void passwordVariantsAreProtectedButLearningFlagAloneIsNotPassword() throws Exception {
        main(() -> {
            EditorInfo info = new EditorInfo();
            for (int type : new int[]{
                InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_PASSWORD,
                InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_WEB_PASSWORD,
                InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD,
                InputType.TYPE_CLASS_NUMBER | InputType.TYPE_NUMBER_VARIATION_PASSWORD}) {
                info.inputType = type;
                assertTrue(SofatapInputMethodService.sensitive(info));
            }
            info.inputType = InputType.TYPE_CLASS_TEXT;
            info.imeOptions = EditorInfo.IME_FLAG_NO_PERSONALIZED_LEARNING;
            assertFalse(SofatapInputMethodService.sensitive(info));
        });
    }

    private String start(String text, boolean sensitive) {
        activity.editor.setText(text);
        activity.editor.setSelection(text.length());
        EditorInfo info = new EditorInfo();
        connection = activity.editor.onCreateInputConnection(info);
        assertNotNull(connection);
        session.start(new ImeSession.Editor() {
            @Override public boolean commit(String value) { return connection.commitText(value, 1); }
            @Override public boolean finishComposing() { return connection.finishComposingText(); }
            @Override public boolean deleteCodePointBeforeCursor() { return connection.deleteSurroundingTextInCodePoints(1, 0); }
            @Override public boolean action(int value) { return connection.performEditorAction(value); }
        }, sensitive, activity.editor.getSelectionStart(), activity.editor.getSelectionEnd(), EditorInfo.IME_ACTION_SEARCH);
        return session.epoch();
    }

    private void selectionChanged() {
        session.selection(activity.editor.getSelectionStart(), activity.editor.getSelectionEnd());
    }
    private ImeSession.Result apply(String type, String epoch, String text) {
        return session.apply(type, epoch, text, () -> true);
    }
    private ImeSession.Result applyWire(String type, String epoch, String text) {
        try {
            JSONObject wire = new JSONObject().put("id", UUID.randomUUID().toString())
                .put("type", type).put("editorEpoch", epoch);
            if (text != null) wire.put("text", text);
            TVProtocol.Action parsed = TVProtocol.parse(wire.toString());
            return apply(parsed.type(), parsed.editorEpoch(), parsed.text());
        } catch (Exception error) { throw new AssertionError(error); }
    }
    private void main(Runnable operation) throws Exception {
        AtomicReference<Throwable> failure = new AtomicReference<>();
        instrumentation.runOnMainSync(() -> { try { operation.run(); } catch (Throwable error) { failure.set(error); } });
        Throwable error = failure.get();
        if (error instanceof Exception) throw (Exception) error;
        if (error instanceof Error) throw (Error) error;
        if (error != null) throw new AssertionError(error);
    }
}
