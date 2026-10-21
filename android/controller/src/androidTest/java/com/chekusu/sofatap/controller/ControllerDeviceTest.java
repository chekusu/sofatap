package com.chekusu.sofatap.controller;

import android.Manifest;
import android.app.Activity;
import android.app.Instrumentation;
import android.content.Context;
import android.content.ContextWrapper;
import android.content.Intent;
import android.content.IntentFilter;
import android.content.pm.ActivityInfo;
import android.content.res.Configuration;
import android.graphics.Bitmap;
import android.graphics.Rect;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;
import android.speech.RecognizerIntent;
import android.view.MotionEvent;
import android.view.View;
import android.view.ViewGroup;
import android.view.accessibility.AccessibilityNodeInfo;
import android.view.inputmethod.InputMethodManager;
import android.widget.EditText;
import android.widget.TextView;

import androidx.test.core.app.ActivityScenario;
import androidx.test.ext.junit.runners.AndroidJUnit4;
import androidx.test.platform.app.InstrumentationRegistry;
import org.json.JSONObject;
import org.junit.After;
import org.junit.Before;
import org.junit.Test;
import org.junit.runner.RunWith;

import java.io.File;
import java.io.FileOutputStream;
import java.net.Inet4Address;
import java.net.InetAddress;
import java.net.NetworkInterface;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.security.MessageDigest;
import java.util.ArrayList;
import java.util.List;
import java.util.Collections;
import java.util.concurrent.CopyOnWriteArrayList;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicReference;
import java.util.function.BooleanSupplier;
import okhttp3.Response;
import okhttp3.WebSocket;
import okhttp3.WebSocketListener;
import okhttp3.mockwebserver.MockResponse;
import okhttp3.mockwebserver.MockWebServer;
import okhttp3.tls.HandshakeCertificates;
import okhttp3.tls.HeldCertificate;

import static org.junit.Assert.*;

/** Native runtime acceptance on an isolated Android emulator, never desktop input injection. */
@RunWith(AndroidJUnit4.class)
public class ControllerDeviceTest {
    private final Instrumentation instrumentation = InstrumentationRegistry.getInstrumentation();
    private ActivityScenario<MainActivity> scenario;
    private MockWebServer server;
    private String pairedIdentity;
    private final List<JSONObject> received = new CopyOnWriteArrayList<>();
    private final AtomicReference<JSONObject> fixtureHello = new AtomicReference<>();
    private final AtomicReference<JSONObject> statusOnAck = new AtomicReference<>();

    @Before public void prepare() throws Exception {
        instrumentation.getUiAutomation().grantRuntimePermission("com.chekusu.sofatap", Manifest.permission.CAMERA);
        scenario = ActivityScenario.launch(MainActivity.class);
        scenario.onActivity(activity -> {
            activity.session.disconnect();
            hideKeyboard(activity);
        });
        instrumentation.waitForIdleSync();
    }

    @After public void cleanUp() throws Exception {
        if (scenario != null) {
            scenario.onActivity(activity -> {
                activity.surface.cancelGesture();
                activity.session.forget();
                hideKeyboard(activity);
                if (pairedIdentity != null) new DeviceStore(activity).remove(pairedIdentity);
                activity.setRequestedOrientation(ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED);
            });
            scenario.close();
        }
        if (server != null) server.shutdown();
    }

    @Test public void portraitLandscapeAndKeyboardKeepComposerUsable() throws Exception {
        scenario.onActivity(a -> a.setRequestedOrientation(ActivityInfo.SCREEN_ORIENTATION_PORTRAIT));
        awaitOrientation(Configuration.ORIENTATION_PORTRAIT);
        scenario.onActivity(a -> {
            a.editor.setText("保留草稿 · 日本語 · 🎮");
            a.editor.setSelection(a.editor.length());
            assertComposerGeometry(a);
        });
        screenshot("controller-portrait.png");
        // First match is the shared keyboard control inside the touch surface.
        clickMainDescription(R.string.keyboard);
        await("software keyboard appears", () -> mainBoolean(a -> imeVisible(a)));
        scenario.onActivity(ControllerDeviceTest::assertComposerGeometry);
        screenshot("controller-keyboard.png");
        clickMainDescription(R.string.hide_keyboard);
        await("software keyboard hides", () -> mainBoolean(a -> !imeVisible(a)));
        scenario.onActivity(a -> a.setRequestedOrientation(ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE));
        awaitOrientation(Configuration.ORIENTATION_LANDSCAPE);
        scenario.onActivity(a -> {
            assertEquals("保留草稿 · 日本語 · 🎮", a.editor.getText().toString());
            assertComposerGeometry(a);
            assertTrue("touch area remains visible", a.surface.getHeight() > a.getResources().getDisplayMetrics().density * 90);
        });
        screenshot("controller-landscape.png");
        clickMainDescription(R.string.keyboard);
        await("landscape keyboard appears", () -> mainBoolean(ControllerDeviceTest::imeVisible));
        SystemClock.sleep(500);
        scenario.onActivity(ControllerDeviceTest::assertComposerGeometry);
        scenario.onActivity(ControllerDeviceTest::assertPadControlsSeparate);
        screenshot("controller-landscape-keyboard.png");
        clickMainDescription(R.string.hide_keyboard);
        await("landscape keyboard hides", () -> mainBoolean(a -> !imeVisible(a)));
        // Recreating also exercises saved-state restoration, not only configChanges handling.
        scenario.recreate();
        scenario.onActivity(a -> assertEquals("保留草稿 · 日本語 · 🎮", a.editor.getText().toString()));
    }

    @Test public void dialogsPairOverTlsAndSendConsecutiveUnicodeDrafts() throws Exception {
        String uri = startDesktopReceiver();
        clickMainDescription(R.string.guide);
        clickDialogText(R.string.done);
        clickMainDescription(R.string.devices);
        assertNotNull(awaitNode(instrumentation.getTargetContext().getString(R.string.devices), false));
        clickDialogText(R.string.done);
        clickMainDescription(R.string.add_device);
        clickDialogText(R.string.paste_link);
        AccessibilityNodeInfo input = awaitEditable();
        Bundle text = new Bundle();
        text.putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, uri);
        assertTrue(input.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, text));
        clickDialogText(R.string.pair);
        await("TLS hello connects and persists the selected device", () -> mainBoolean(a -> a.session.connected()));
        scenario.onActivity(a -> {
            assertEquals("windows", a.session.status.platform);
            assertEquals(pairedIdentity, new DeviceStore(a).selectedId());
            a.editor.setText("你好，Windows 🎮\n日本語テスト");
        });
        clickMainDescription(R.string.send);
        await("first Unicode draft acknowledged and cleared", () -> mainBoolean(a -> a.editor.length() == 0));
        assertEquals(List.of("你好，Windows 🎮\n日本語テスト"), textMessages());
        scenario.onActivity(a -> {
            a.editor.setText("追加：");
            a.editor.setSelection(a.editor.length());
        });
        // The Android activity-result mechanism is real; only the external recognition service
        // is stubbed. This tests result delivery, not microphone/audio recognition accuracy.
        Intent result = new Intent();
        result.putStringArrayListExtra(RecognizerIntent.EXTRA_RESULTS, new ArrayList<>(List.of("第二段语音 🛋️")));
        Instrumentation.ActivityMonitor speech = instrumentation.addMonitor(
                new IntentFilter(RecognizerIntent.ACTION_RECOGNIZE_SPEECH),
                new Instrumentation.ActivityResult(Activity.RESULT_OK, result), true);
        try {
            clickMainDescription(R.string.dictate);
            await("speech result appended to current draft", () -> mainBoolean(a -> "追加：第二段语音 🛋️".equals(a.editor.getText().toString())));
            assertEquals(1, speech.getHits());
        } finally { instrumentation.removeMonitor(speech); }
        await("session active after speech UI", () -> mainBoolean(a -> a.session.connected()));
        clickMainDescription(R.string.send);
        await("new recognition result acknowledged and cleared", () -> mainBoolean(a -> a.editor.length() == 0));
        assertEquals(List.of("你好，Windows 🎮\n日本語テスト", "追加：第二段语音 🛋️"), textMessages());
        clickMainDescription(R.string.backspace);
        await("backspace command is on the wire", () -> received.stream().anyMatch(j -> "key".equals(j.optString("type")) && "backspace".equals(j.optString("key"))));
        assertEquals("no duplicate text sends", 2, textMessages().size());
        scenario.onActivity(a -> a.session.disconnect());
        await("disconnection replaces stale Sent status", () -> mainBoolean(a -> !a.session.connected()
                && hasText(a.getWindow().getDecorView(),a.getString(R.string.no_device))
                && !hasText(a.getWindow().getDecorView(),a.getString(R.string.sent))));
    }

    @Test public void nativeTouchDispatchProducesMoveClickDragAndOppositeScrollFrames() throws Exception {
        String uri = startDesktopReceiver();
        scenario.onActivity(a -> a.pair(uri));
        await("fixture connected", () -> mainBoolean(a -> a.session.connected()));
        gesture(100, 180, 145, 195, 80);
        await("pointer move", () -> count("move") > 0);
        tapSurface(80, 180);
        await("left single click (received " + received + ")", () -> count("click") == 1);
        scenario.onActivity(a -> a.surface.cancelGesture());
        runGesture(new long[]{0, 340, 360}, new int[]{MotionEvent.ACTION_DOWN, MotionEvent.ACTION_MOVE, MotionEvent.ACTION_UP},
                new float[][]{{100,180}, {130,185}, {130,185}}, false);
        await("drag release", () -> received.stream().anyMatch(j -> "button".equals(j.optString("type")) && !j.optBoolean("down", true)));
        assertTrue(received.stream().anyMatch(j -> "button".equals(j.optString("type")) && j.optBoolean("down")));
        received.clear();
        twoFingerScroll();
        await("natural scroll", () -> count("scroll") > 0);
        JSONObject natural = received.stream().filter(j -> "scroll".equals(j.optString("type"))).findFirst().get();
        assertTrue("two fingers down use positive wheel delta", natural.getDouble("dy") > 0);
        received.clear();
        AtomicReference<Float> edge = new AtomicReference<>();
        scenario.onActivity(a -> edge.set(a.surface.getWidth() / a.getResources().getDisplayMetrics().density - 10));
        gesture(edge.get(), 180, edge.get(), 220, 80);
        await("edge scroll", () -> count("scroll") > 0);
        JSONObject edgeScroll = received.stream().filter(j -> "scroll".equals(j.optString("type"))).findFirst().get();
        assertTrue("edge down uses negative wheel delta", edgeScroll.getDouble("dy") < 0);
    }

    @Test public void androidKeystorePersistsRenameAndCredentialWithoutPlaintext() throws Exception {
        Context context = instrumentation.getTargetContext();
        File directory = new File(context.getNoBackupFilesDir(), "instrumentation-" + System.nanoTime());
        assertTrue(directory.mkdirs());
        Context isolated = new ContextWrapper(context) {
            @Override public File getNoBackupFilesDir() { return directory; }
        };
        String token = "AndroidKeystoreTestToken0000000000000000000";
        String uri = "sofatap://pair?host=localhost&port=53319&token=" + token + "&fingerprint=" + "ab".repeat(32) + "&name=Fixture";
        Pairing pairing = Pairing.parse(uri);
        DeviceStore store = new DeviceStore(isolated);
        store.save(pairing);
        store.rename(pairing.identity(), "测试电脑 🎮");
        DeviceStore reopened = new DeviceStore(isolated);
        assertEquals("测试电脑 🎮", reopened.selected().name);
        assertEquals(token, reopened.selected().pairing.token);
        File encrypted = new File(directory, "paired-devices.enc");
        String contents = new String(Files.readAllBytes(encrypted.toPath()), StandardCharsets.UTF_8);
        assertFalse(contents.contains(token));
        assertFalse(contents.contains("测试电脑"));
        reopened.remove(pairing.identity());
        assertTrue(new DeviceStore(isolated).list().isEmpty());
        assertTrue(encrypted.delete());
        assertTrue(directory.delete());
    }

    @Test public void tvModeKeepsSharedControlsAndRoutesNavigationAndEditorEpoch() throws Exception {
        AtomicReference<Rect> keyboardBefore = new AtomicReference<>(), micBefore = new AtomicReference<>();
        scenario.onActivity(a -> {
            keyboardBefore.set(bounds(findDescription(a.getWindow().getDecorView(), a.getString(R.string.keyboard))));
            micBefore.set(bounds(findDescription(a.getWindow().getDecorView(), a.getString(R.string.dictate))));
        });
        String uri = startReceiver(true);
        scenario.onActivity(a -> a.pair(uri));
        await("TV hello authenticated", () -> mainBoolean(a -> a.session.connected()));
        // A ready TV editor can auto-open the keyboard; compare layouts in the same hidden state.
        scenario.onActivity(ControllerDeviceTest::hideKeyboard);
        await("TV keyboard hides for navigation", () -> mainBoolean(a -> !imeVisible(a)));
        SystemClock.sleep(250);
        scenario.onActivity(a -> {
            assertEquals("androidtv", a.session.status.platform);
            assertEquals(keyboardBefore.get(), bounds(findDescription(a.getWindow().getDecorView(), a.getString(R.string.keyboard))));
            assertEquals(micBefore.get(), bounds(findDescription(a.getWindow().getDecorView(), a.getString(R.string.dictate))));
        });
        tapSurface(100, 180);
        await("TV tap confirms", () -> hasKey("remote_key", "confirm"));
        gesture(100, 180, 100, 130, 80);
        await("TV swipe navigates", () -> hasKey("remote_key", "up"));
        clickMainDescription(R.string.back);
        clickMainDescription(R.string.home);
        await("TV Back and Home buttons", () -> hasKey("remote_key", "back") && hasKey("remote_key", "home"));
        scenario.onActivity(a -> a.editor.setText("电视搜索 🎬"));
        clickMainDescription(R.string.send);
        await("TV text committed", () -> count("text_commit") == 1 && mainBoolean(a -> a.editor.length() == 0));
        JSONObject text = received.stream().filter(j -> "text_commit".equals(j.optString("type"))).findFirst().get();
        assertEquals("电视搜索 🎬", text.getString("text"));
        assertEquals("a8e57498-a7d2-4a82-9d28-b34c830ac7db", text.getString("editorEpoch"));
        clickMainDescription(R.string.backspace);
        clickMainDescription(R.string.enter);
        await("TV keyboard actions", () -> count("text_backspace") == 1 && count("text_action") == 1);
        assertEquals(0, count("move"));
        assertEquals(0, count("click"));
        clickMainDescription(R.string.guide);
        assertNotNull(awaitNode(instrumentation.getTargetContext().getString(R.string.guide_tv), false));
        screenshot("controller-tv-guide.png");
        clickDialogText(R.string.done);
        screenshot("controller-tv.png");
    }

    @Test public void editorFocusWhileGuideOpenShowsKeyboardOnceAfterDismissal() throws Exception {
        String uri = startReceiver(true);
        scenario.onActivity(a -> a.pair(uri));
        await("TV ready", () -> mainBoolean(a -> a.session.connected()));
        await("initial editor keyboard", () -> mainBoolean(ControllerDeviceTest::imeVisible));
        scenario.onActivity(ControllerDeviceTest::hideKeyboard);
        await("initial keyboard hidden", () -> mainBoolean(a -> !imeVisible(a)));
        clickMainDescription(R.string.guide);
        String epoch = "84d99b25-e490-4c40-847d-22d183a245e8";
        JSONObject update = new JSONObject(fixtureHello.get().toString());
        update.getJSONObject("tvControls").put("editorEpoch",epoch);
        statusOnAck.set(update);
        scenario.onActivity(a -> assertTrue(a.session.send(WireActions.ping(),null)));
        await("new editor reaches phone behind guide", () -> mainBoolean(a -> epoch.equals(a.session.status.editorEpoch)));
        assertFalse("guide does not expose keyboard",mainBoolean(ControllerDeviceTest::imeVisible));
        clickDialogText(R.string.done);
        await("guide dismissal opens new editor keyboard", () -> mainBoolean(ControllerDeviceTest::imeVisible));
        clickMainDescription(R.string.hide_keyboard);
        await("manual keyboard dismissal", () -> mainBoolean(a -> !imeVisible(a)));
        for(int i=0;i<3;i++) {
            scenario.onActivity(a -> assertTrue(a.session.send(WireActions.ping(),null)));
            SystemClock.sleep(450);
            assertFalse("same editor heartbeat respects dismissal",mainBoolean(ControllerDeviceTest::imeVisible));
        }
    }

    private String startDesktopReceiver() throws Exception {
        return startReceiver(false);
    }
    private String startReceiver(boolean tv) throws Exception {
        String host = tv ? privateAddress() : "localhost";
        HeldCertificate certificate = new HeldCertificate.Builder().commonName(host).addSubjectAlternativeName(host).build();
        HandshakeCertificates tls = new HandshakeCertificates.Builder().heldCertificate(certificate).build();
        server = new MockWebServer();
        server.useHttps(tls.sslSocketFactory(), false);
        String hello = tv
                ? "{\"type\":\"hello\",\"version\":1,\"name\":\"Acceptance TV\",\"platform\":\"androidtv\",\"inputAvailable\":true,\"inputStatus\":\"ready\",\"pairingToken\":\"" + "b".repeat(43) + "\",\"capabilities\":{\"overlayCursor\":true,\"nodeClick\":true,\"scroll\":true,\"back\":true,\"home\":true,\"directionalFocus\":true,\"text\":false,\"rawMouse\":false,\"rightClick\":false,\"drag\":false},\"tvControls\":{\"version\":1,\"navigationStatus\":\"ready\",\"textStatus\":\"ready\",\"editorEpoch\":\"a8e57498-a7d2-4a82-9d28-b34c830ac7db\"}}"
                : "{\"type\":\"hello\",\"version\":1,\"name\":\"Acceptance computer\",\"platform\":\"windows\",\"inputAvailable\":true,\"inputStatus\":\"ready\",\"dryRun\":false}";
        fixtureHello.set(new JSONObject(hello));
        MockResponse response = new MockResponse().withWebSocketUpgrade(new WebSocketListener() {
            @Override public void onOpen(WebSocket socket, Response ignored) {
                try {
                    JSONObject message = new JSONObject(hello);
                    if (tv && ("Bearer " + "b".repeat(43)).equals(ignored.request().header("Authorization"))) message.remove("pairingToken");
                    socket.send(message.toString());
                } catch (Exception bad) { throw new AssertionError(bad); }
            }
            @Override public void onMessage(WebSocket socket, String text) {
                try {
                    JSONObject action = new JSONObject(text);
                    if (!"ping".equals(action.optString("type"))) received.add(action);
                    JSONObject ack = new JSONObject().put("type","ack").put("id",action.getString("id")).put("ok",true);
                    JSONObject status = statusOnAck.get();
                    if(status!=null) for(String key : new String[]{"inputAvailable","inputStatus","dryRun","capabilities","tvControls","textFocus"})
                        if(status.has(key)) ack.put(key,status.get(key));
                    socket.send(ack.toString());
                } catch (Exception bad) { throw new AssertionError(bad); }
            }
        });
        // Dialog/recognition transitions may reconnect legitimately; use the same pinned identity.
        for (int i = 0; i < 12; i++) server.enqueue(response);
        server.start(InetAddress.getByName(tv ? "0.0.0.0" : "localhost"), 0);
        byte[] bytes = MessageDigest.getInstance("SHA-256").digest(certificate.certificate().getEncoded());
        StringBuilder pin = new StringBuilder();
        for (byte b : bytes) pin.append(String.format(java.util.Locale.ROOT, "%02x", b & 255));
        String uri = "sofatap://" + (tv ? "tv" : "pair") + "?host=" + host + "&port=" + server.getPort() + "&token=" + "a".repeat(43) + "&fingerprint=" + pin + "&platform=" + (tv ? "androidtv" : "windows") + "&name=Acceptance%20" + (tv ? "TV" : "computer");
        pairedIdentity = Pairing.parse(uri).identity();
        return uri;
    }
    private static String privateAddress() throws Exception {
        for (NetworkInterface network : Collections.list(NetworkInterface.getNetworkInterfaces()))
            for (InetAddress address : Collections.list(network.getInetAddresses()))
                if (address instanceof Inet4Address && address.isSiteLocalAddress()) return address.getHostAddress();
        throw new AssertionError("TV fixture needs an isolated emulator private IPv4 interface");
    }
    private boolean hasKey(String type, String key) {
        return received.stream().anyMatch(j -> type.equals(j.optString("type")) && key.equals(j.optString("key")));
    }
    private static Rect bounds(View view) {
        assertNotNull(view);
        Rect bounds = new Rect(); assertTrue(view.getGlobalVisibleRect(bounds)); return bounds;
    }

    private void clickMainDescription(int string) {
        scenario.onActivity(a -> {
            View view = findDescription(a.getWindow().getDecorView(), a.getString(string));
            assertNotNull("Missing control: " + a.getString(string), view);
            assertTrue("Control disabled: " + a.getString(string), view.isEnabled());
            assertTrue(view.performClick());
        });
        instrumentation.waitForIdleSync();
    }
    private static boolean hasText(View view,String value) {
        if(view instanceof TextView text && value.contentEquals(text.getText()) && text.isShown()) return true;
        if(view instanceof ViewGroup group) for(int i=0;i<group.getChildCount();i++) if(hasText(group.getChildAt(i),value)) return true;
        return false;
    }
    private static View findDescription(View root, String value) {
        if (!(root instanceof TouchSurfaceView) && value.contentEquals(root.getContentDescription() == null ? "" : root.getContentDescription()) && root.isShown() && root.getGlobalVisibleRect(new Rect())) return root;
        if (root instanceof ViewGroup group) for (int i = 0; i < group.getChildCount(); i++) {
            View found = findDescription(group.getChildAt(i), value); if (found != null) return found;
        }
        return null;
    }
    private void clickDialogText(int id) {
        AccessibilityNodeInfo node = awaitNode(instrumentation.getTargetContext().getString(id), false);
        while (node != null && !node.isClickable()) node = node.getParent();
        assertNotNull(node); assertTrue(node.performAction(AccessibilityNodeInfo.ACTION_CLICK));
        instrumentation.waitForIdleSync();
    }
    private AccessibilityNodeInfo awaitNode(String text, boolean editable) {
        AtomicReference<AccessibilityNodeInfo> result = new AtomicReference<>();
        await("dialog control " + text, () -> {
            result.set(findNode(instrumentation.getUiAutomation().getRootInActiveWindow(), text, editable));
            return result.get() != null;
        });
        return result.get();
    }
    private AccessibilityNodeInfo awaitEditable() { return awaitNode("", true); }
    private static AccessibilityNodeInfo findNode(AccessibilityNodeInfo node, String text, boolean editable) {
        if (node == null) return null;
        if (editable ? node.isEditable() : text.equalsIgnoreCase(node.getText() == null ? "" : node.getText().toString())) return node;
        for (int i = 0; i < node.getChildCount(); i++) { AccessibilityNodeInfo found = findNode(node.getChild(i), text, editable); if (found != null) return found; }
        return null;
    }

    private interface ActivityCondition { boolean test(MainActivity activity); }
    private boolean mainBoolean(ActivityCondition condition) {
        AtomicBoolean result = new AtomicBoolean();
        scenario.onActivity(a -> result.set(condition.test(a)));
        return result.get();
    }
    private static void await(String description, BooleanSupplier condition) {
        long deadline = SystemClock.uptimeMillis() + 12000;
        while (SystemClock.uptimeMillis() < deadline) {
            if (condition.getAsBoolean()) return;
            SystemClock.sleep(80);
        }
        fail("Timed out: " + description);
    }
    private void awaitOrientation(int orientation) {
        await("orientation", () -> mainBoolean(a -> a.getResources().getConfiguration().orientation == orientation));
        SystemClock.sleep(250);
        instrumentation.waitForIdleSync();
    }
    private static void hideKeyboard(MainActivity activity) {
        ((InputMethodManager)activity.getSystemService(Context.INPUT_METHOD_SERVICE)).hideSoftInputFromWindow(activity.editor.getWindowToken(), 0);
        activity.editor.clearFocus();
    }
    private static boolean imeVisible(MainActivity activity) {
        return activity.getWindow().getDecorView().getRootWindowInsets() != null
                && activity.getWindow().getDecorView().getRootWindowInsets().isVisible(android.view.WindowInsets.Type.ime());
    }
    private static void assertComposerGeometry(MainActivity activity) {
        View send = findDescription(activity.getWindow().getDecorView(), activity.getString(R.string.send));
        View clear = findDescription(activity.getWindow().getDecorView(), activity.getString(R.string.clear));
        assertNotNull(send); assertNotNull(clear);
        Rect sendBounds = new Rect(), fieldBounds = new Rect(), clearBounds = new Rect();
        assertTrue(send.getGlobalVisibleRect(sendBounds));
        assertTrue(activity.editor.getGlobalVisibleRect(fieldBounds));
        assertTrue(clear.getGlobalVisibleRect(clearBounds));
        assertTrue("submit sits inside the editor", fieldBounds.contains(sendBounds));
        assertTrue("text has space reserved before submit", fieldBounds.right - activity.editor.getPaddingRight() <= sendBounds.left);
        assertTrue("draft tools are below the editor", clearBounds.top >= fieldBounds.bottom);
        assertTrue("tools must not overlap submit", !Rect.intersects(clearBounds, sendBounds));
    }
    private static void assertPadControlsSeparate(MainActivity activity) {
        View root = activity.getWindow().getDecorView();
        View keyboard = findDescription(root, activity.getString(imeVisible(activity) ? R.string.hide_keyboard : R.string.keyboard));
        View microphone = findDescription(root, activity.getString(R.string.dictate));
        Rect keyboardBounds = bounds(keyboard), microphoneBounds = bounds(microphone);
        assertEquals("keyboard control is fully visible", keyboard.getHeight(), keyboardBounds.height());
        assertEquals("microphone control is fully visible", microphone.getHeight(), microphoneBounds.height());
        assertFalse("keyboard and microphone do not overlap", Rect.intersects(keyboardBounds,microphoneBounds));
        for (int id : new int[]{R.string.devices,R.string.add_device,R.string.guide}) {
            View top = findDescription(root,activity.getString(id));
            Rect topBounds = bounds(top);
            assertEquals("header control is fully visible",top.getHeight(),topBounds.height());
            assertFalse("header does not overlap keyboard",Rect.intersects(topBounds,keyboardBounds));
            assertFalse("header does not overlap microphone",Rect.intersects(topBounds,microphoneBounds));
        }
    }

    private void screenshot(String name) throws Exception {
        // Insets visibility becomes true before the keyboard animation finishes.
        SystemClock.sleep(500);
        instrumentation.waitForIdleSync();
        Bitmap screenshot = instrumentation.getUiAutomation().takeScreenshot();
        assertNotNull(screenshot);
        File directory = new File(instrumentation.getTargetContext().getExternalFilesDir(null), "acceptance");
        assertTrue(directory.isDirectory() || directory.mkdirs());
        try (FileOutputStream file = new FileOutputStream(new File(directory, name))) {
            assertTrue(screenshot.compress(Bitmap.CompressFormat.PNG, 100, file));
        } finally { screenshot.recycle(); }
    }

    private long count(String type) { return received.stream().filter(j -> type.equals(j.optString("type"))).count(); }
    private List<String> textMessages() {
        List<String> results = new ArrayList<>();
        for (JSONObject value : received) if ("text".equals(value.optString("type"))) results.add(value.optString("text"));
        return results;
    }
    private void tapSurface(float x, float y) {
        runGesture(new long[]{0,40}, new int[]{MotionEvent.ACTION_DOWN,MotionEvent.ACTION_UP},
                new float[][]{{x,y},{x,y}}, false);
    }
    private void gesture(float x, float y, float endX, float endY, long duration) {
        runGesture(new long[]{0,duration,duration+10}, new int[]{MotionEvent.ACTION_DOWN,MotionEvent.ACTION_MOVE,MotionEvent.ACTION_UP},
                new float[][]{{x,y},{endX,endY},{endX,endY}}, false);
    }
    private void twoFingerScroll() {
        runGesture(new long[]{0,10,60,80,90}, new int[]{MotionEvent.ACTION_DOWN,
                        MotionEvent.ACTION_POINTER_DOWN | 1 << MotionEvent.ACTION_POINTER_INDEX_SHIFT,
                        MotionEvent.ACTION_MOVE, MotionEvent.ACTION_POINTER_UP | 1 << MotionEvent.ACTION_POINTER_INDEX_SHIFT,
                        MotionEvent.ACTION_UP},
                new float[][]{{100,180},{100,180},{100,220},{100,220},{100,220}}, true);
    }
    private void runGesture(long[] delays, int[] actions, float[][] points, boolean multi) {
        CountDownLatch done = new CountDownLatch(1);
        AtomicReference<Throwable> failure = new AtomicReference<>();
        scenario.onActivity(a -> {
            long down = SystemClock.uptimeMillis();
            Handler main = new Handler(Looper.getMainLooper());
            for (int i = 0; i < delays.length; i++) {
                final int index = i;
                main.postDelayed(() -> {
                    try {
                        float scale = a.getResources().getDisplayMetrics().density;
                        long time = SystemClock.uptimeMillis();
                        MotionEvent event;
                        if (multi && index > 0 && index < delays.length - 1) {
                            MotionEvent.PointerProperties[] properties = new MotionEvent.PointerProperties[2];
                            MotionEvent.PointerCoords[] coords = new MotionEvent.PointerCoords[2];
                            for (int p = 0; p < 2; p++) {
                                properties[p] = new MotionEvent.PointerProperties(); properties[p].id = p; properties[p].toolType = MotionEvent.TOOL_TYPE_FINGER;
                                coords[p] = new MotionEvent.PointerCoords(); coords[p].x = (points[index][0] + p * 70) * scale;
                                coords[p].y = points[index][1] * scale; coords[p].pressure = 1; coords[p].size = 1;
                            }
                            event = MotionEvent.obtain(down,time,actions[index],2,properties,coords,0,0,1,1,0,0,android.view.InputDevice.SOURCE_TOUCHSCREEN,0);
                        } else event = MotionEvent.obtain(down,time,actions[index],points[index][0]*scale,points[index][1]*scale,0);
                        assertTrue(a.surface.dispatchTouchEvent(event));
                        event.recycle();
                    } catch (Throwable problem) { failure.compareAndSet(null,problem); }
                    finally { if (index == delays.length - 1) done.countDown(); }
                }, delays[index]);
            }
        });
        try { assertTrue("gesture dispatch completed",done.await(5,TimeUnit.SECONDS)); }
        catch (InterruptedException interrupted) { Thread.currentThread().interrupt(); throw new AssertionError(interrupted); }
        if(failure.get()!=null) throw new AssertionError(failure.get());
    }
}
