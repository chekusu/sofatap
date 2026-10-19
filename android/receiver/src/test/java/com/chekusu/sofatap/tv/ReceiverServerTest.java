package com.chekusu.sofatap.tv;

import okhttp3.*;
import okhttp3.tls.HandshakeCertificates;
import okhttp3.tls.HeldCertificate;
import org.json.JSONObject;
import org.junit.After;
import org.junit.Before;
import org.junit.Test;
import javax.net.ssl.*;
import java.io.*;
import java.net.InetAddress;
import java.nio.charset.StandardCharsets;
import java.security.KeyStore;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.function.BooleanSupplier;
import static org.junit.Assert.*;

/** Actual loopback TLS, independent OkHttp client, and hand-built malformed wire frames. */
public class ReceiverServerTest {
    private ReceiverServer server;
    private PairingAuthority authority;
    private FakeInput input;
    private OkHttpClient client;
    private SSLContext trustedTls;
    private SSLContext serverTls;
    private String bootstrap;
    private final List<SocketPeer> peers = new ArrayList<>();
    private final List<SSLSocket> rawSockets = new ArrayList<>();

    @Before public void startLoopbackReceiver() throws Exception {
        HeldCertificate certificate = ReceiverCertificate.generate(Collections.singletonList("127.0.0.1"));
        HandshakeCertificates trusted = new HandshakeCertificates.Builder().addTrustedCertificate(certificate.certificate()).build();
        trustedTls = trusted.sslContext();
        KeyStore keys = KeyStore.getInstance(KeyStore.getDefaultType()); keys.load(null);
        keys.setKeyEntry("test", certificate.keyPair().getPrivate(), "test".toCharArray(),
            new java.security.cert.Certificate[]{certificate.certificate()});
        KeyManagerFactory manager = KeyManagerFactory.getInstance(KeyManagerFactory.getDefaultAlgorithm());
        manager.init(keys, "test".toCharArray());
        serverTls = SSLContext.getInstance("TLS"); serverTls.init(manager.getKeyManagers(), null, null);
        authority = new PairingAuthority(null, System::currentTimeMillis, digest -> {});
        bootstrap = authority.newPairing(); input = new FakeInput();
        server = new ReceiverServer(serverTls, InetAddress.getByName("127.0.0.1"), 0, authority, input, "Local test");
        server.start();
        client = new OkHttpClient.Builder().sslSocketFactory(trusted.sslSocketFactory(), trusted.trustManager())
            .connectTimeout(2, TimeUnit.SECONDS).readTimeout(3, TimeUnit.SECONDS).build();
    }

    @After public void stopAllLocalResources() throws Exception {
        input.release.countDown(); input.releaseDisconnect.countDown(); server.close();
        for (SocketPeer peer : peers) if (peer.socket != null) peer.socket.cancel();
        for (SSLSocket socket : rawSockets) socket.close();
        client.connectionPool().evictAll(); client.dispatcher().executorService().shutdownNow();
    }

    @Test public void bootstrapRotatesThenPersistentTokenReconnectsWithoutReenrolling() throws Exception {
        SocketPeer first = connect(bootstrap); JSONObject hello = first.message();
        assertEquals("hello", hello.getString("type")); assertEquals("androidtv", hello.getString("platform"));
        String token = hello.getString("pairingToken"); assertNotEquals(bootstrap, token);
        assertNull(authority.bootstrap()); assertTrue(authority.paired());
        first.socket.cancel(); await(() -> !server.connected());
        SocketPeer resumed = connect(token); assertFalse(resumed.message().has("pairingToken"));
        assertTrue(resumed.socket.send(action(UUID.randomUUID().toString(), "click")));
        assertTrue(resumed.message().getBoolean("ok")); assertEquals(1, input.applied.get());
    }

    @Test public void authenticatedAppShortcutIsAcknowledgedOnceWithAnOptionalTopLevelCapability() throws Exception {
        input.nativeControls = true;
        SocketPeer peer = connect(bootstrap); JSONObject hello = peer.message();
        assertEquals(1, hello.getJSONObject("appShortcuts").getInt("schema"));
        assertEquals("youtube", hello.getJSONObject("appShortcuts").getJSONArray("availableApps").getString(0));
        assertFalse("Old iOS strictly parses this object", hello.getJSONObject("tvControls").has("appShortcuts"));
        String id = UUID.randomUUID().toString();
        String command = new JSONObject(action(id, "app_launch")).put("app", "youtube").toString();
        peer.socket.send(command); peer.socket.send(command);
        for (int i = 0; i < 2; i++) {
            JSONObject ack = peer.message();
            assertEquals(id, ack.getString("id")); assertTrue(ack.getBoolean("ok"));
            assertTrue(ack.has("appShortcuts"));
        }
        assertEquals(1, input.applied.get()); assertEquals("youtube", input.received.get(0).app());
        input.rejectedCode = "app_not_installed";
        peer.socket.send(new JSONObject(action(UUID.randomUUID().toString(), "app_launch")).put("app", "netflix").toString());
        JSONObject missing = peer.message();
        assertFalse(missing.getBoolean("ok")); assertEquals("app_not_installed", missing.getString("error"));
        assertTrue(server.connected());
    }

    @Test public void rapidNativeNavigationAndTextKeepTheirOrderAndDoNotDisconnect() throws Exception {
        input.nativeControls = true;
        SocketPeer peer = connect(bootstrap); peer.message();
        List<String> ids = new ArrayList<>();
        for (int repeat = 0; repeat < 4; repeat++) {
            for (String key : new String[]{"up", "down", "left", "right", "confirm", "back", "home"}) {
                String id = UUID.randomUUID().toString(); ids.add(id);
                assertTrue(peer.socket.send(new JSONObject(action(id, "remote_key")).put("key", key).toString()));
            }
        }
        String textId = UUID.randomUUID().toString(); ids.add(textId);
        peer.socket.send(new JSONObject(action(textId, "text_commit")).put("editorEpoch", input.editorEpoch.toUpperCase(Locale.ROOT))
            .put("text", "中文 日本語 🛋️ after navigation").toString());
        for (String id : ids) {
            JSONObject ack = peer.message(); assertEquals(id, ack.getString("id")); assertTrue(ack.getBoolean("ok"));
        }
        assertEquals(ids.size(), input.applied.get());
        assertEquals(input.editorEpoch, input.received.get(ids.size() - 1).editorEpoch());
        assertTrue(server.connected());
    }

    @Test public void naturalWorkerExitInvalidatesOldInputBeforeAReplacementCanAcquireHello() throws Exception {
        SocketPeer first = connect(bootstrap); String token = first.message().getString("pairingToken");
        input.blockDisconnect = true;
        first.socket.cancel();
        assertTrue(input.disconnectEntered.await(2, TimeUnit.SECONDS));
        SocketPeer resumed = connect(token);
        // The replacement connection blocks at listener registration or ownership
        // acquisition while the old driver's invalidation is deliberately held here.
        await(() -> Thread.getAllStackTraces().entrySet().stream().anyMatch(entry ->
            entry.getKey().getState() == Thread.State.BLOCKED && Arrays.stream(entry.getValue()).anyMatch(frame ->
                frame.getClassName().equals(ReceiverServer.class.getName()) &&
                    (frame.getMethodName().equals("handle") || frame.getMethodName().equals("accept")))));
        assertTrue("New hello must wait for old-session invalidation", resumed.messages.isEmpty());
        input.blockDisconnect = false; input.releaseDisconnect.countDown();
        assertEquals("hello", resumed.message().getString("type"));
        resumed.socket.send(action(UUID.randomUUID().toString(), "click"));
        assertTrue(resumed.message().getBoolean("ok"));
        assertEquals(1, input.disconnections.get()); assertEquals(1, input.applied.get()); assertTrue(server.connected());
    }

    @Test public void extendedActionsCarryFreshStatusWithLegacyAccessibilityUnavailable() throws Exception {
        input.nativeControls = true;
        SocketPeer peer = connect(bootstrap); JSONObject hello = peer.message();
        assertFalse(hello.getBoolean("inputAvailable"));
        assertFalse(hello.getJSONObject("capabilities").getBoolean("text"));
        assertEquals("ready", hello.getJSONObject("tvControls").getString("navigationStatus"));
        String command = new JSONObject().put("id", UUID.randomUUID().toString()).put("type", "remote_key").put("key", "confirm").toString();
        peer.socket.send(command); JSONObject keyAck = peer.message();
        assertTrue(keyAck.getBoolean("ok")); assertFalse(keyAck.getBoolean("inputAvailable"));
        assertEquals("accessibility_required", keyAck.getString("inputStatus"));
        assertEquals(input.editorEpoch, keyAck.getJSONObject("tvControls").getString("editorEpoch"));
        input.editorEpoch = UUID.randomUUID().toString();
        peer.socket.send(action(UUID.randomUUID().toString(), "ping"));
        assertEquals(input.editorEpoch, peer.message().getJSONObject("tvControls").getString("editorEpoch"));
        peer.socket.send(command); assertEquals(keyAck.toString(), peer.message().toString());
        assertEquals(1, input.applied.get()); // Extended inputs retain the existing no-replay guarantee.
        input.rejectedCode = "stale_editor";
        peer.socket.send(new JSONObject().put("id", UUID.randomUUID().toString()).put("type", "text_backspace").put("editorEpoch", UUID.randomUUID().toString()).toString());
        JSONObject stale = peer.message(); assertFalse(stale.getBoolean("ok"));
        assertEquals("stale_editor", stale.getString("error"));
        assertEquals(input.editorEpoch, stale.getJSONObject("tvControls").getString("editorEpoch"));
    }

    @Test public void productionPeerPolicyAllowsOnlyPrivateIpv4AndLoopbackRequiresExplicitTestBind() throws Exception {
        for (String host : Arrays.asList("10.0.0.1", "172.16.0.1", "172.31.255.254", "192.168.1.8"))
            assertTrue(host, ReceiverServer.allowsPeer(InetAddress.getByName(host), false));
        for (String host : Arrays.asList("127.0.0.1", "0.0.0.0", "172.15.255.255", "172.32.0.1",
            "169.254.1.8", "100.64.0.1", "8.8.8.8", "224.0.0.1", "::1", "fd00::1", "fe80::1", "2606:4700:4700::1111"))
            assertFalse(host, ReceiverServer.allowsPeer(InetAddress.getByName(host), false));
        assertTrue(ReceiverServer.allowsPeer(InetAddress.getByName("127.0.0.1"), true));
        assertTrue(ReceiverServer.allowsPeer(InetAddress.getByName("::1"), true));
        assertFalse(ReceiverServer.allowsPeer(InetAddress.getByName("8.8.8.8"), true));
    }

    @Test public void wrongCredentialIsRejectedBeforeUpgradeAndCannotConsumeQrOrSendInput() throws Exception {
        SocketPeer denied = connect("x".repeat(43)); assertEquals(401, denied.failedStatus());
        await(() -> !server.connected()); assertEquals(bootstrap, authority.bootstrap()); assertEquals(0, input.applied.get());
        assertNotNull(connect(bootstrap).message().getString("pairingToken"));
    }

    @Test public void aSecondControllerIsRefusedWithoutBreakingTheFirst() throws Exception {
        SocketPeer first = connect(bootstrap); String token = first.message().getString("pairingToken");
        SocketPeer second = connect(token); assertEquals(409, second.failedStatus());
        String id = UUID.randomUUID().toString(); first.socket.send(action(id, "click"));
        assertEquals(id, first.message().getString("id")); assertEquals(1, input.applied.get());
    }

    @Test public void identicalRetransmissionReturnsSameAckWithoutRepeatingPhysicalInput() throws Exception {
        SocketPeer peer = connect(bootstrap); peer.message(); String message = action(UUID.randomUUID().toString(), "click");
        peer.socket.send(message); JSONObject first = peer.message();
        peer.socket.send(message); JSONObject second = peer.message();
        assertEquals(first.toString(), second.toString()); assertEquals(1, input.applied.get());
    }

    @Test public void reusingIdWithChangedActionFailsAndDisconnects() throws Exception {
        SocketPeer peer = connect(bootstrap); peer.message(); String id = UUID.randomUUID().toString();
        peer.socket.send(action(id, "click")); assertTrue(peer.message().getBoolean("ok"));
        peer.socket.send(action(id, "ping")); JSONObject failure = peer.message();
        assertFalse(failure.getBoolean("ok")); assertEquals("id_reused", failure.getString("error"));
        await(() -> !server.connected()); assertEquals(1, input.applied.get());
    }

    @Test public void invalidActionCannotReachInputAndIsAcknowledgedAsFailure() throws Exception {
        SocketPeer peer = connect(bootstrap); peer.message(); peer.socket.send(action(UUID.randomUUID().toString(), "shell"));
        JSONObject failure = peer.message(); assertFalse(failure.getBoolean("ok"));
        assertEquals("invalid_action", failure.getString("error")); assertEquals(0, input.applied.get());
        await(() -> !server.connected());
    }

    @Test public void inaccessibleClickReportsItsActualReasonAndLeavesOtherControlsConnected() throws Exception {
        SocketPeer peer = connect(bootstrap); peer.message();
        input.rejectedCode = "no_accessible_target";
        String click = action(UUID.randomUUID().toString(), "click");
        peer.socket.send(click);
        JSONObject rejected = peer.message();
        assertFalse(rejected.getBoolean("ok"));
        assertEquals("no_accessible_target", rejected.getString("error"));
        assertEquals(1, input.applied.get());
        assertTrue(server.connected());

        // Receiving the same negative ACK again must not turn a pointer click
        // into another action, such as confirmation of the currently focused item.
        peer.socket.send(click);
        assertEquals(rejected.toString(), peer.message().toString());
        assertEquals(1, input.applied.get());
        input.rejectedCode = null;
        peer.socket.send(scroll(UUID.randomUUID().toString(), 0, 1200));
        assertTrue(peer.message().getBoolean("ok"));
        peer.socket.send(new JSONObject(action(UUID.randomUUID().toString(), "key"))
            .put("key", "back").toString());
        assertTrue(peer.message().getBoolean("ok"));
        assertTrue(server.connected());
        assertEquals(3, input.applied.get());
    }

    @Test public void orderedScrollBurstWithDelayedInputAcknowledgesEveryActionWithoutDisconnecting() throws Exception {
        SocketPeer peer = connect(bootstrap); peer.message(); input.delayMillis = 20;
        List<String> ids = new ArrayList<>();
        for (int i = 0; i < 60; i++) {
            String id = UUID.randomUUID().toString(); ids.add(id);
            assertTrue(peer.socket.send(scroll(id, 0, i < 30 ? 1200 : -1200)));
        }
        for (String id : ids) {
            JSONObject ack = peer.message();
            assertEquals(id, ack.getString("id")); assertTrue(ack.getBoolean("ok"));
        }
        assertEquals(ids.size(), input.applied.get());
        assertTrue(server.connected());
    }

    @Test public void backAfterPendingScrollPreservesItsWireMeaningAndReportsARejectedGlobalAction() throws Exception {
        SocketPeer peer = connect(bootstrap); peer.message(); input.block = true;
        String scrollId = UUID.randomUUID().toString();
        peer.socket.send(scroll(scrollId, 0, 1200));
        assertTrue(input.entered.await(2, TimeUnit.SECONDS));
        String backId = UUID.randomUUID().toString();
        peer.socket.send(new JSONObject(action(backId, "key")).put("key", "back").toString());
        input.rejectedKey = "back"; input.release.countDown();
        JSONObject scrollAck = peer.message();
        assertEquals(scrollId, scrollAck.getString("id")); assertTrue(scrollAck.getBoolean("ok"));
        JSONObject backAck = peer.message();
        assertEquals(backId, backAck.getString("id")); assertFalse(backAck.getBoolean("ok"));
        assertEquals("action_rejected", backAck.getString("error"));
        assertEquals(2, input.received.size());
        TVProtocol.Action back = input.received.get(1);
        assertEquals("key", back.type()); assertEquals("back", back.key());
        assertEquals(0, back.dx(), 0); assertEquals(0, back.dy(), 0);
        assertTrue(server.connected());
        peer.socket.send(action(UUID.randomUUID().toString(), "ping"));
        assertTrue(peer.message().getBoolean("ok"));
    }

    private static String scroll(String id, double dx, double dy) throws Exception {
        return new JSONObject(action(id, "scroll")).put("dx", dx).put("dy", dy).toString();
    }

    @Test public void binaryAndOversizedTextNeverReachInput() throws Exception {
        SocketPeer binary = connect(bootstrap); String token = binary.message().getString("pairingToken");
        binary.socket.send(okio.ByteString.encodeUtf8(action(UUID.randomUUID().toString(), "click")));
        await(() -> !server.connected()); assertEquals(0, input.applied.get());
        SocketPeer oversized = connect(token); oversized.message();
        oversized.socket.send("🙂".repeat(16385)); // 65,540 UTF-8 bytes, despite fewer UTF-16 characters.
        await(() -> !server.connected()); assertEquals(0, input.applied.get());
    }

    @Test public void fragmentedTextWithInterleavedPingExecutesOnce() throws Exception {
        RawPeer peer = rawConnect(bootstrap); peer.message();
        byte[] message = action(UUID.randomUUID().toString(), "click").getBytes(StandardCharsets.UTF_8);
        peer.frame(0x01, Arrays.copyOfRange(message, 0, 12));
        peer.frame(0x89, new byte[]{1, 2, 3});
        RawFrame pong = peer.receive(); assertEquals(10, pong.opcode); assertArrayEquals(new byte[]{1, 2, 3}, pong.body);
        peer.frame(0x80, Arrays.copyOfRange(message, 12, message.length));
        assertTrue(peer.message().getBoolean("ok")); assertEquals(1, input.applied.get());
    }

    @Test public void orphanContinuationAndNewTextDuringFragmentAreRejected() throws Exception {
        RawPeer orphan = rawConnect(bootstrap); String token = orphan.message().getString("pairingToken");
        orphan.frame(0x80, new byte[0]); await(() -> !server.connected()); assertEquals(0, input.applied.get());
        RawPeer nested = rawConnect(token); nested.message(); nested.frame(0x01, new byte[]{'{'});
        nested.frame(0x81, action(UUID.randomUUID().toString(), "click").getBytes(StandardCharsets.UTF_8));
        await(() -> !server.connected()); assertEquals(0, input.applied.get());
    }

    @Test public void aggregateFragmentLimitAndFrameCountLimitAreEnforced() throws Exception {
        RawPeer oversized = rawConnect(bootstrap); String token = oversized.message().getString("pairingToken");
        oversized.frame(0x01, new byte[40000]); oversized.frame(0x80, new byte[30000]);
        await(() -> !server.connected()); assertEquals(0, input.applied.get());
        RawPeer fragmented = rawConnect(token); fragmented.message(); fragmented.frame(0x01, new byte[0]);
        for (int i = 0; i < 255; i++) fragmented.frame(0x00, new byte[0]);
        await(() -> !server.connected()); assertEquals(0, input.applied.get());
    }

    @Test public void revokedGenerationCancelsAnAlreadyQueuedActionBeforeInput() throws Exception {
        SocketPeer peer = connect(bootstrap); String token = peer.message().getString("pairingToken");
        input.block = true; peer.socket.send(action(UUID.randomUUID().toString(), "click"));
        assertTrue(input.entered.await(2, TimeUnit.SECONDS)); authority.revoke(); server.disconnectController();
        input.release.countDown(); await(() -> !server.connected()); assertEquals(0, input.applied.get());
        assertEquals(401, connect(token).failedStatus());
    }

    @Test public void disconnectWithoutRevocationImmediatelyInvalidatesQueuedInputAndNotifiesOnce() throws Exception {
        SocketPeer peer = connect(bootstrap); String token = peer.message().getString("pairingToken");
        long generation = authority.generation();
        input.block = true; peer.socket.send(action(UUID.randomUUID().toString(), "click"));
        assertTrue(input.entered.await(2, TimeUnit.SECONDS));
        BooleanSupplier oldSession = input.current;
        Thread oldWorker = input.applyThread;

        server.disconnectController();
        assertFalse("Disconnect must release ownership before returning", server.connected());
        assertFalse("Queued input must be invalid before TLS cleanup finishes", oldSession.getAsBoolean());
        assertEquals("Disconnect must not revoke the saved pairing", generation, authority.generation());
        assertEquals(1, input.disconnections.get());
        server.disconnectController();
        assertEquals("Repeated disconnect must not repeat input cleanup", 1, input.disconnections.get());

        input.release.countDown();
        await(() -> input.cancelled.get() == 1);
        awaitHandlerExit(oldWorker);
        assertEquals(0, input.applied.get());
        assertEquals("Worker finalization must not notify a second time", 1, input.disconnections.get());
        SocketPeer resumed = connect(token);
        assertFalse(resumed.message().has("pairingToken"));
    }

    @Test public void oldWorkerFinalizationCannotDisconnectANewAuthenticatedController() throws Exception {
        SocketPeer old = connect(bootstrap); String token = old.message().getString("pairingToken");
        input.block = true; old.socket.send(action(UUID.randomUUID().toString(), "click"));
        assertTrue(input.entered.await(2, TimeUnit.SECONDS));
        Thread oldWorker = input.applyThread;
        server.disconnectController();

        // Keep the old input callback blocked until a distinct worker owns the new session.
        SocketPeer resumed = connect(token); resumed.message();
        assertTrue(server.connected());
        input.block = false; input.release.countDown();
        await(() -> input.cancelled.get() == 1);
        awaitHandlerExit(oldWorker);
        assertEquals(0, input.applied.get());
        assertEquals("Old finally must not clear the new controller", 1, input.disconnections.get());
        assertTrue(server.connected());

        String id = UUID.randomUUID().toString();
        resumed.socket.send(action(id, "click"));
        JSONObject ack = resumed.message();
        assertEquals(id, ack.getString("id")); assertTrue(ack.getBoolean("ok"));
        assertEquals(1, input.applied.get());
        resumed.socket.cancel();
        await(() -> !server.connected() && input.disconnections.get() == 2);
    }

    @Test public void stoppedListenerReleasesItsPortAndRepeatedCloseLeavesReplacementAlone() throws Exception {
        SocketPeer peer = connect(bootstrap); String token = peer.message().getString("pairingToken");
        int port = server.port();
        FakeInput replacementInput = new FakeInput();
        server.close();
        assertFalse(server.connected()); assertEquals(1, input.disconnections.get());
        assertTrue("Background setup must await accept termination before rebinding",
            server.awaitListenerStopped(2, TimeUnit.SECONDS));
        // Exercise the real listener's socket options, not a test socket that adds reuse itself.
        // No bind retry, client closure or polling after the production completion signal.
        try (ReceiverServer replacement = new ReceiverServer(serverTls, InetAddress.getByName("127.0.0.1"),
                port, authority, replacementInput, "Replacement test")) {
            replacement.start();
            SocketPeer resumed = connect(replacement, token);
            assertFalse(resumed.message().has("pairingToken"));
            server.close(); server.disconnectController(); server.close();
            String id = UUID.randomUUID().toString();
            resumed.socket.send(action(id, "ping"));
            JSONObject ack = resumed.message();
            assertEquals(id, ack.getString("id")); assertTrue(ack.getBoolean("ok"));
            assertTrue(replacement.connected());
            assertEquals(port, replacement.port());
            assertEquals(1, input.disconnections.get());
            assertEquals(0, replacementInput.disconnections.get());
            assertEquals(0, replacementInput.applied.get());
        }
    }

    @Test public void closingBeforeStartSignalsListenerTerminationAndCannotStartAcceptingLater() throws Exception {
        FakeInput neverStartedInput = new FakeInput();
        try (ReceiverServer neverStarted = new ReceiverServer(serverTls, InetAddress.getByName("127.0.0.1"),
                0, authority, neverStartedInput, "Never started")) {
            neverStarted.close();
            assertTrue("Closing a bound but unstarted listener must signal completion",
                neverStarted.awaitListenerStopped(0, TimeUnit.SECONDS));
            neverStarted.start();
            assertTrue(neverStarted.awaitListenerStopped(0, TimeUnit.SECONDS));
            assertFalse(neverStarted.connected());
            assertNotNull("Starting a closed server must not reopen its listener",
                connect(neverStarted, bootstrap).failure.poll(3, TimeUnit.SECONDS));
            assertEquals("An unstarted listener cannot consume enrollment", bootstrap, authority.bootstrap());
            assertEquals(0, neverStartedInput.applied.get());
            assertEquals(0, neverStartedInput.disconnections.get());
        }
    }

    @Test public void closingServerCancelsQueuedActionAndStopsNewConnections() throws Exception {
        SocketPeer peer = connect(bootstrap); peer.message(); input.block = true;
        peer.socket.send(action(UUID.randomUUID().toString(), "click")); assertTrue(input.entered.await(2, TimeUnit.SECONDS));
        server.close(); input.release.countDown(); await(() -> !server.connected()); assertEquals(0, input.applied.get());
        assertNotNull(connect(bootstrap).failure.poll(3, TimeUnit.SECONDS));
    }

    @Test public void incompleteTlsIsClosedByOverallHandshakeDeadline() throws Exception {
        java.net.Socket socket = new java.net.Socket("127.0.0.1", server.port());
        try {
            socket.setSoTimeout(7000);
            // A JSSE provider may send a TLS alert before closing an incomplete handshake.
            InputStream stream = socket.getInputStream(); int received = 0;
            try { while (stream.read() != -1) assertTrue("Unbounded handshake response", ++received < 1024); }
            catch (java.net.SocketException reset) { /* Bounded abort may use RST instead of TLS close_notify. */ }
        }
        finally { socket.close(); }
        assertEquals(0, input.applied.get()); assertFalse(server.connected());
    }

    private static final class FakeInput implements ReceiverServer.Input {
        final AtomicInteger applied = new AtomicInteger(); final CountDownLatch entered = new CountDownLatch(1), release = new CountDownLatch(1);
        final AtomicInteger cancelled = new AtomicInteger(), disconnections = new AtomicInteger();
        volatile BooleanSupplier current;
        volatile Thread applyThread;
        volatile boolean block;
        volatile String rejectedCode;
        volatile String rejectedKey;
        volatile long delayMillis;
        final List<TVProtocol.Action> received = new CopyOnWriteArrayList<>();
        volatile boolean nativeControls;
        volatile String editorEpoch = UUID.randomUUID().toString();
        public JSONObject snapshot() throws Exception {
            JSONObject status = new JSONObject().put("ready", true);
            if (nativeControls) status.put("inputAvailable", false).put("inputStatus", "accessibility_required")
                .put("capabilities", new JSONObject().put("text", false))
                .put("tvControls", new JSONObject().put("version", 1).put("navigationStatus", "ready").put("textStatus", "ready").put("editorEpoch", editorEpoch))
                .put("appShortcuts", new JSONObject().put("schema", 1).put("availableApps", new org.json.JSONArray().put("youtube").put("netflix")));
            return status;
        }
        public JSONObject apply(TVProtocol.Action action, BooleanSupplier current) throws Exception {
            this.current = current; applyThread = Thread.currentThread();
            entered.countDown(); if (block) release.await(3, TimeUnit.SECONDS);
            if (delayMillis > 0) Thread.sleep(delayMillis);
            if (!current.getAsBoolean()) {
                cancelled.incrementAndGet();
                return new JSONObject().put("ok", false).put("code", "cancelled");
            }
            applied.incrementAndGet(); received.add(action);
            if (action.key() != null && action.key().equals(rejectedKey))
                return new JSONObject().put("ok", false).put("code", "action_rejected");
            if (rejectedCode != null) return new JSONObject().put("ok", false).put("code", rejectedCode);
            return new JSONObject().put("ok", true);
        }
        volatile boolean blockDisconnect;
        final CountDownLatch disconnectEntered = new CountDownLatch(1), releaseDisconnect = new CountDownLatch(1);
        public void disconnected() {
            disconnections.incrementAndGet();
            if (blockDisconnect) {
                disconnectEntered.countDown();
                try { releaseDisconnect.await(5, TimeUnit.SECONDS); } catch (InterruptedException interrupted) { Thread.currentThread().interrupt(); }
            }
        }
    }

    private final class SocketPeer extends WebSocketListener {
        WebSocket socket; final BlockingQueue<String> messages = new LinkedBlockingQueue<>();
        final BlockingQueue<Integer> statuses = new LinkedBlockingQueue<>(); final BlockingQueue<Throwable> failure = new LinkedBlockingQueue<>();
        @Override public void onMessage(WebSocket ws, String text) { messages.add(text); }
        @Override public void onFailure(WebSocket ws, Throwable problem, Response response) { statuses.add(response == null ? 0 : response.code()); failure.add(problem); }
        JSONObject message() throws Exception { String text = messages.poll(3, TimeUnit.SECONDS); assertNotNull("Missing server message; failure=" + failure.peek(), text); return new JSONObject(text); }
        int failedStatus() throws Exception { Integer status = statuses.poll(3, TimeUnit.SECONDS); assertNotNull("Expected upgrade refusal", status); return status; }
    }
    private SocketPeer connect(String token) {
        return connect(server, token);
    }
    private SocketPeer connect(ReceiverServer target, String token) {
        SocketPeer peer = new SocketPeer(); peers.add(peer);
        peer.socket = client.newWebSocket(new Request.Builder().url("wss://127.0.0.1:" + target.port() + "/control")
            .header("Authorization", "Bearer " + token).build(), peer); return peer;
    }

    private final class RawPeer {
        final DataInputStream in; final DataOutputStream out;
        RawPeer(SSLSocket socket) throws IOException { in = new DataInputStream(socket.getInputStream()); out = new DataOutputStream(socket.getOutputStream()); }
        void frame(int first, byte[] body) throws IOException {
            out.writeByte(first); if (body.length < 126) out.writeByte(0x80 | body.length);
            else if (body.length <= 65535) { out.writeByte(0xfe); out.writeShort(body.length); }
            else { out.writeByte(0xff); out.writeLong(body.length); }
            byte[] mask = {0x37, (byte)0xfa, 0x21, 0x3d}; out.write(mask);
            byte[] masked = body.clone(); for (int i = 0; i < masked.length; i++) masked[i] ^= mask[i % 4];
            out.write(masked); out.flush();
        }
        RawFrame receive() throws IOException {
            int first = in.readUnsignedByte(), length = in.readUnsignedByte();
            if ((length & 128) != 0) throw new IOException("Server frame must not be masked");
            long size = length == 126 ? in.readUnsignedShort() : length == 127 ? in.readLong() : length;
            if (size > 65536) throw new IOException("Oversized server response");
            byte[] body = new byte[(int)size]; in.readFully(body); return new RawFrame(first & 15, body);
        }
        JSONObject message() throws Exception { RawFrame frame = receive(); assertEquals(1, frame.opcode); return new JSONObject(new String(frame.body, StandardCharsets.UTF_8)); }
    }
    private record RawFrame(int opcode, byte[] body) { }
    private RawPeer rawConnect(String token) throws Exception {
        SSLSocket socket = (SSLSocket)trustedTls.getSocketFactory().createSocket("127.0.0.1", server.port());
        rawSockets.add(socket); socket.setSoTimeout(3000); socket.startHandshake(); RawPeer peer = new RawPeer(socket);
        peer.out.write(("GET /control HTTP/1.1\r\nHost: 127.0.0.1:" + server.port() + "\r\nUpgrade: websocket\r\n"
            + "Connection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"
            + "Authorization: Bearer " + token + "\r\n\r\n").getBytes(StandardCharsets.US_ASCII)); peer.out.flush();
        ByteArrayOutputStream headers = new ByteArrayOutputStream(); int suffix = 0;
        while (headers.size() < 8192 && suffix != 0x0d0a0d0a) { int b = peer.in.read(); if (b < 0) throw new EOFException(); headers.write(b); suffix = suffix << 8 | b; }
        assertTrue(headers.toString("US-ASCII").startsWith("HTTP/1.1 101 ")); return peer;
    }
    private static String action(String id, String type) throws Exception { return new JSONObject().put("id", id).put("type", type).toString(); }
    private static void awaitHandlerExit(Thread worker) throws Exception {
        // Observe completion of the actual handler, including its finally block, without
        // adding a production hook or shutting down the newly authenticated session.
        await(() -> Arrays.stream(worker.getStackTrace()).noneMatch(frame ->
            frame.getClassName().equals(ReceiverServer.class.getName()) && frame.getMethodName().equals("handle")));
    }
    private static void await(BooleanSupplier condition) throws Exception {
        long until = System.nanoTime() + TimeUnit.SECONDS.toNanos(3);
        while (!condition.getAsBoolean() && System.nanoTime() < until) Thread.sleep(10);
        assertTrue("Condition not reached within 3 seconds", condition.getAsBoolean());
    }
}
