package com.chekusu.sofatap.controller;

import static org.junit.Assert.*;
import static org.junit.Assume.assumeTrue;
import org.junit.Test;
import org.json.JSONArray;
import org.json.JSONObject;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.util.concurrent.BlockingQueue;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.LinkedBlockingQueue;
import java.util.concurrent.TimeUnit;
import java.util.function.Predicate;
import javax.crypto.KeyGenerator;
import javax.crypto.SecretKey;

/** Opt-in compatibility check against tests/device-harness, never a platform input injector. */
public class ProductionReceiverCompatibilityTest {
    private static final class Connection implements PinnedSocket.Listener, AutoCloseable {
        final BlockingQueue<JSONObject> messages = new LinkedBlockingQueue<>();
        final CountDownLatch failure = new CountDownLatch(1);
        final PinnedSocket socket;
        Connection(Pairing pairing) {
            socket = new PinnedSocket(pairing, this, Runnable::run);
            socket.connect();
        }
        @Override public void onOpen() { }
        @Override public void onMessage(JSONObject message) { messages.add(message); }
        @Override public void onFailure(boolean retryable) { failure.countDown(); }
        @Override public void onClosed() { }
        JSONObject receive() throws Exception {
            JSONObject value = messages.poll(5, TimeUnit.SECONDS);
            assertNotNull("Recording receiver did not return a protocol message", value);
            assertEquals("Pinned transport failed", 1, failure.getCount());
            return value;
        }
        JSONObject apply(JSONObject action) throws Exception {
            assertTrue("Recording receiver did not accept the outgoing command", socket.send(action));
            JSONObject ack = receive();
            assertEquals("ack", ack.getString("type"));
            assertTrue("Receiver acknowledged a different action", action.getString("id").equals(ack.getString("id")));
            assertTrue("Recording receiver rejected a controller command", ack.getBoolean("ok"));
            return ack;
        }
        @Override public void close() { socket.close(); }
    }

    @Test public void realPinnedReceiverAcceptsInputAndSavedIdentityReconnects() throws Exception {
        String configured = System.getenv("SOFATAP_CONTROLLER_HARNESS_DIR");
        assumeTrue("Requires an explicitly started recording-only device harness", configured != null && !configured.isBlank());
        Path directory = Path.of(configured).toRealPath();
        JSONObject initial = state(directory);
        assertEquals("Use a fresh recording harness for this test", 0, initial.getJSONObject("actions").getInt("text"));
        assertEquals("", initial.getString("text"));
        assertEquals(0, initial.getJSONObject("clicks").getInt("left"));
        assertEquals(0, initial.getJSONObject("clicks").getInt("right"));

        // Pairing data is read only from the owner's private handoff file, never from test logs.
        JSONObject handoff = read(directory.resolve("pairing.json"));
        JSONArray advertised = handoff.getJSONArray("pairings");
        assertTrue("Recording harness has no pairing endpoint", advertised.length() > 0);
        Pairing advertisedPairing = Pairing.parse(advertised.getJSONObject(0).getString("uri"));
        // The production certificate includes loopback SANs. Do not contact a physical device.
        Pairing pairing = Pairing.fromJson(advertisedPairing.toJson().put("host", "127.0.0.1"));
        assertFalse("A desktop recording harness is required", pairing.isTv());

        Path savedFile = directory.resolve("android-controller-paired-devices.enc");
        assertFalse("The private test store must be new", Files.exists(savedFile));
        KeyGenerator generator = KeyGenerator.getInstance("AES"); generator.init(256);
        SecretKey key = generator.generateKey();
        DeviceStore devices = new DeviceStore(savedFile.toFile(), key);
        devices.save(pairing);
        devices.rename(pairing.identity(), "Recording receiver");

        int releasesBeforeClose;
        try (Connection connection = new Connection(pairing)) {
            ReceiverStatus status = ReceiverStatus.fromHello(connection.receive(), false);
            assertTrue("Recording receiver must be ready", status.ready && status.canText && status.canDrag);

            // 'text' is the harness fixture. The production wire value must be 'editable'.
            setFocus(directory, "text", 1);
            JSONObject focusAck = connection.apply(WireActions.ping());
            assertEquals("editable", focusAck.getJSONObject("textFocus").getString("state"));
            status = status.withUpdate(focusAck);
            assertEquals("editable", status.focusState);
            assertTrue(status.focusRevision > 0);

            String sample = "Android 遥控 日本語 café e\u0301 👩‍💻";
            connection.apply(WireActions.text(pairing, status, sample));
            assertEquals(sample, state(directory).getString("text"));
            connection.apply(WireActions.backspace(pairing, status));
            assertEquals("Android 遥控 日本語 café e\u0301 ", state(directory).getString("text"));
            connection.apply(WireActions.enter(pairing, status));
            assertTrue(state(directory).getString("text").endsWith("\n"));
            connection.apply(WireActions.key(pairing, status, "selectAll"));
            JSONObject selected = state(directory);
            assertEquals(selected.getString("text").length(), selected.getJSONObject("selection").getInt("length"));
            connection.apply(WireActions.text(pairing, status, "Sofatap ✓"));
            assertEquals("Sofatap ✓", state(directory).getString("text"));

            connection.apply(WireActions.click(pairing, false));
            connection.apply(WireActions.click(pairing, false));
            connection.apply(WireActions.click(pairing, true));
            connection.apply(WireActions.button(pairing, true));
            assertEquals("left", state(directory).getJSONArray("buttons").getString(0));
            connection.apply(WireActions.move(pairing, 30, -20));
            connection.apply(WireActions.button(pairing, false));
            connection.apply(WireActions.scroll(pairing, 12, -24));
            JSONObject pointerState = state(directory);
            assertEquals(430, pointerState.getJSONObject("pointer").getDouble("x"), .001);
            assertEquals(230, pointerState.getJSONObject("pointer").getDouble("y"), .001);
            assertEquals(12, pointerState.getJSONObject("scroll").getDouble("x"), .001);
            assertEquals(-24, pointerState.getJSONObject("scroll").getDouble("y"), .001);
            assertEquals(2, pointerState.getJSONObject("clicks").getInt("left"));
            assertEquals(1, pointerState.getJSONObject("clicks").getInt("right"));
            assertEquals(0, pointerState.getJSONArray("buttons").length());

            // The production action session, rather than a mock server, deduplicates delivery.
            JSONObject duplicate = WireActions.text(pairing, status, " · once");
            connection.apply(duplicate); connection.apply(duplicate);
            assertEquals("Sofatap ✓ · once", state(directory).getString("text"));
            assertEquals(3, state(directory).getJSONObject("actions").getInt("text"));

            setFocus(directory, "protected", 2);
            ReceiverStatus protectedStatus = status.withUpdate(connection.apply(WireActions.ping()));
            assertEquals("protected", protectedStatus.focusState);

            // A lost foreground connection must release a held drag at the receiver.
            connection.apply(WireActions.button(pairing, true));
            releasesBeforeClose = state(directory).getInt("releases");
        }
        awaitState(directory, value -> value.optInt("releases") > releasesBeforeClose && value.optJSONArray("buttons").length() == 0);

        DeviceStore reopened = new DeviceStore(savedFile.toFile(), key);
        assertEquals(1, reopened.list().size());
        assertEquals("Recording receiver", reopened.selected().name);
        assertTrue("Saved identity changed", pairing.identity().equals(reopened.selected().pairing.identity()));
        assertTrue("Saved certificate pin changed", pairing.fingerprint.equals(reopened.selected().pairing.fingerprint));
        String ciphertext = new String(Files.readAllBytes(savedFile), StandardCharsets.ISO_8859_1);
        assertFalse("Pairing credential leaked into the stored file", ciphertext.contains(pairing.token));
        try (Connection reconnected = new Connection(reopened.selected().pairing)) {
            ReceiverStatus resumed = ReceiverStatus.fromHello(reconnected.receive(), false);
            assertTrue(resumed.ready);
            reconnected.apply(WireActions.text(pairing, resumed, " · reconnected"));
            assertEquals("Sofatap ✓ · once · reconnected", state(directory).getString("text"));
        }
    }

    private static JSONObject read(Path file) throws Exception {
        assertTrue("Missing private harness file", Files.isRegularFile(file));
        assertTrue("Oversized private harness file", Files.size(file) <= 1024 * 1024);
        return new JSONObject(new String(Files.readAllBytes(file), StandardCharsets.UTF_8));
    }
    private static JSONObject state(Path directory) throws Exception {
        JSONObject value = read(directory.resolve("state.json"));
        assertEquals("isolated-recording-only", value.getString("mode"));
        assertFalse("This test must never use an OS input injector", value.getBoolean("osInjection"));
        return value;
    }
    private static void setFocus(Path directory, String focus, int revision) throws Exception {
        Path temporary = Files.createTempFile(directory, "android-focus-", ".tmp");
        Files.write(temporary, new JSONObject().put("focus", focus).put("revision", revision).toString().getBytes(StandardCharsets.UTF_8));
        Files.move(temporary, directory.resolve("control.json"), StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING);
    }
    private static void awaitState(Path directory, Predicate<JSONObject> condition) throws Exception {
        long deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(5);
        do {
            if (condition.test(state(directory))) return;
            Thread.sleep(25);
        } while (System.nanoTime() < deadline);
        fail("Recording receiver did not complete disconnect cleanup");
    }
}
