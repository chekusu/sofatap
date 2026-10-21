package com.chekusu.sofatap.controller;

import static org.junit.Assert.*;
import org.junit.Test;
import org.json.JSONObject;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.cert.CertificateException;
import java.security.cert.X509Certificate;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import okhttp3.Response;
import okhttp3.WebSocket;
import okhttp3.WebSocketListener;
import okhttp3.mockwebserver.MockResponse;
import okhttp3.mockwebserver.MockWebServer;
import okhttp3.mockwebserver.RecordedRequest;
import okhttp3.tls.HandshakeCertificates;
import okhttp3.tls.HeldCertificate;
import okio.ByteString;

public class PinnedSocketTest {
    private static final String TOKEN = "test_only_not_a_real_token_0123456789012345678";
    private static final class Events implements PinnedSocket.Listener {
        final CountDownLatch opened = new CountDownLatch(1), received = new CountDownLatch(1), failed = new CountDownLatch(1);
        volatile JSONObject message;
        volatile boolean retryable;
        public void onOpen() { opened.countDown(); }
        public void onMessage(JSONObject message) { this.message = message; received.countDown(); }
        public void onFailure(boolean retryable) { this.retryable = retryable; failed.countDown(); }
        public void onClosed() { }
    }
    private static HeldCertificate certificate(String san) {
        return new HeldCertificate.Builder().commonName("Sofatap test receiver").addSubjectAlternativeName(san).build();
    }
    private static String pin(HeldCertificate certificate) throws Exception {
        byte[] bytes = MessageDigest.getInstance("SHA-256").digest(certificate.certificate().getEncoded());
        StringBuilder hex = new StringBuilder();
        for (byte value : bytes) hex.append(String.format("%02x", value & 255));
        return hex.toString();
    }
    private static MockWebServer server(HeldCertificate certificate) throws Exception {
        MockWebServer server = new MockWebServer();
        server.useHttps(new HandshakeCertificates.Builder().heldCertificate(certificate).build().sslSocketFactory(), false);
        server.start();
        return server;
    }
    private static Pairing pairing(MockWebServer server, String pin) {
        return Pairing.parse("sofatap://pair?host=localhost&port=" + server.getPort() + "&token=" + TOKEN + "&fingerprint=" + pin);
    }
    private static void awaited(CountDownLatch latch) throws Exception { assertTrue("Event timed out", latch.await(5, TimeUnit.SECONDS)); }

    @Test public void pinnedTlsUsesSanAndHeaderAndExchangesText() throws Exception {
        HeldCertificate certificate = certificate("localhost");
        try (MockWebServer server = server(certificate)) {
            CountDownLatch sent = new CountDownLatch(1);
            server.enqueue(new MockResponse().withWebSocketUpgrade(new WebSocketListener() {
                @Override public void onOpen(WebSocket socket, Response response) { socket.send("{\"type\":\"hello\"}"); }
                @Override public void onMessage(WebSocket socket, String text) { if (text.equals("{\"type\":\"click\"}")) sent.countDown(); }
            }));
            Events events = new Events();
            PinnedSocket socket = new PinnedSocket(pairing(server, pin(certificate)), events, Runnable::run);
            try {
                socket.connect(); awaited(events.opened); awaited(events.received);
                assertEquals("hello", events.message.getString("type"));
                assertTrue(socket.send(new JSONObject().put("type", "click"))); awaited(sent);
                RecordedRequest request = server.takeRequest(2, TimeUnit.SECONDS);
                assertNotNull(request);
                assertEquals("/control", request.getPath());
                assertEquals("Bearer " + TOKEN, request.getHeader("Authorization"));
                assertFalse(request.getPath().contains(TOKEN));
            } finally { socket.close(); }
        }
    }

    @Test public void wrongPinFailsBeforeAuthorizationReachesReceiver() throws Exception {
        HeldCertificate certificate = certificate("localhost");
        try (MockWebServer server = server(certificate)) {
            Events events = new Events();
            PinnedSocket socket = new PinnedSocket(pairing(server, "a".repeat(64)), events, Runnable::run);
            try {
                socket.connect(); awaited(events.failed);
                assertFalse(events.retryable); assertEquals(1, events.opened.getCount());
                assertNull(server.takeRequest(200, TimeUnit.MILLISECONDS));
            } finally { socket.close(); }
        }
    }

    @Test public void matchingPinCannotBypassWrongSan() throws Exception {
        HeldCertificate certificate = certificate("some-other-host.local");
        try (MockWebServer server = server(certificate)) {
            Events events = new Events();
            PinnedSocket socket = new PinnedSocket(pairing(server, pin(certificate)), events, Runnable::run);
            try {
                socket.connect(); awaited(events.failed);
                assertFalse(events.retryable); assertNull(server.takeRequest(200, TimeUnit.MILLISECONDS));
            } finally { socket.close(); }
        }
    }

    @Test public void redirectsNeverForwardCredentials() throws Exception {
        HeldCertificate certificate = certificate("localhost");
        try (MockWebServer source = server(certificate); MockWebServer destination = server(certificate)) {
            source.enqueue(new MockResponse().setResponseCode(302).addHeader("Location", destination.url("/control")));
            Events events = new Events();
            PinnedSocket socket = new PinnedSocket(pairing(source, pin(certificate)), events, Runnable::run);
            try {
                socket.connect(); awaited(events.failed);
                assertFalse(events.retryable);
                assertNotNull(source.takeRequest(1, TimeUnit.SECONDS));
                assertNull(destination.takeRequest(200, TimeUnit.MILLISECONDS));
            } finally { socket.close(); }
        }
    }

    @Test public void expiredPairedCertificateIsRejected() throws Exception {
        HeldCertificate expired = new HeldCertificate.Builder().commonName("localhost").addSubjectAlternativeName("localhost")
            .validityInterval(1, 1000).build();
        try {
            PinnedSocket.trustManager(pin(expired)).checkServerTrusted(new X509Certificate[] {expired.certificate()}, "RSA");
            fail("Expired certificate accepted");
        } catch (CertificateException expected) { }
    }

    @Test public void busyPinnedReceiverCanRetryButAuthenticationCannot() throws Exception {
        HeldCertificate certificate = certificate("localhost");
        try (MockWebServer server = server(certificate)) {
            for (int code : new int[] {409, 401, 403}) {
                server.enqueue(new MockResponse().setResponseCode(code));
                Events events = new Events();
                PinnedSocket socket = new PinnedSocket(pairing(server, pin(certificate)), events, Runnable::run);
                try {
                    socket.connect(); awaited(events.failed);
                    assertEquals("Incorrect retry classification for HTTP " + code, code == 409, events.retryable);
                    assertEquals(1, events.opened.getCount());
                    assertNotNull(server.takeRequest(1, TimeUnit.SECONDS));
                } finally { socket.close(); }
            }
        }
    }

    @Test public void binaryMalformedAndOversizedMessagesFailClosed() throws Exception {
        String[] invalid = {"not json", "{\"value\":\"" + "x".repeat(PinnedSocket.MAX_MESSAGE_BYTES) + "\"}",
            "{} trailing", "{/*comment*/\"ok\":1}", "{unquoted:1}",
            "{\"nested\":" + "[".repeat(40) + "0" + "]".repeat(40) + "}"};
        for (int variant = 0; variant < invalid.length + 1; variant++) {
            final int mode = variant;
            HeldCertificate certificate = certificate("localhost");
            try (MockWebServer server = server(certificate)) {
                server.enqueue(new MockResponse().withWebSocketUpgrade(new WebSocketListener() {
                    @Override public void onOpen(WebSocket socket, Response response) {
                        if (mode == 0) socket.send(ByteString.of(new byte[] {1, 2, 3}));
                        else socket.send(invalid[mode - 1]);
                    }
                }));
                Events events = new Events();
                PinnedSocket socket = new PinnedSocket(pairing(server, pin(certificate)), events, Runnable::run);
                try {
                    socket.connect(); awaited(events.failed); assertFalse(events.retryable);
                    assertEquals(1, events.received.getCount());
                } finally { socket.close(); }
            }
        }
    }

    @Test public void outgoingLimitCountsUtf8Bytes() throws Exception {
        HeldCertificate certificate = certificate("localhost");
        try (MockWebServer server = server(certificate)) {
            server.enqueue(new MockResponse().withWebSocketUpgrade(new WebSocketListener() { }));
            Events events = new Events();
            PinnedSocket socket = new PinnedSocket(pairing(server, pin(certificate)), events, Runnable::run);
            try {
                socket.connect(); awaited(events.opened);
                assertFalse(socket.send(new JSONObject().put("text", "界".repeat(23000))));
                assertEquals(1, events.failed.getCount());
            } finally { socket.close(); }
        }
    }
}
