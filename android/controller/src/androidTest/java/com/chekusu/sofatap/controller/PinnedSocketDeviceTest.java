package com.chekusu.sofatap.controller;

import static org.junit.Assert.*;
import android.os.Looper;
import androidx.test.ext.junit.runners.AndroidJUnit4;
import org.json.JSONObject;
import org.junit.Test;
import org.junit.runner.RunWith;
import java.net.InetAddress;
import java.security.MessageDigest;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;
import okhttp3.Response;
import okhttp3.WebSocket;
import okhttp3.WebSocketListener;
import okhttp3.mockwebserver.MockResponse;
import okhttp3.mockwebserver.MockWebServer;
import okhttp3.tls.HandshakeCertificates;
import okhttp3.tls.HeldCertificate;

/** Real Android JSONObject/Looper regression over a loopback pinned TLS WebSocket. */
@RunWith(AndroidJUnit4.class)
public class PinnedSocketDeviceTest {
    private static final String TOKEN = "test_only_not_a_real_token_0123456789012345678";
    private static final class Events implements PinnedSocket.Listener {
        final CountDownLatch failed = new CountDownLatch(1), received = new CountDownLatch(1);
        final AtomicInteger delivered = new AtomicInteger();
        volatile boolean retryable, callbackOnMain;
        volatile JSONObject message;
        public void onOpen() { }
        public void onMessage(JSONObject value) {
            callbackOnMain = Looper.myLooper() == Looper.getMainLooper();
            message = value; delivered.incrementAndGet(); received.countDown();
        }
        public void onFailure(boolean retryable) {
            callbackOnMain = Looper.myLooper() == Looper.getMainLooper();
            this.retryable = retryable; failed.countDown();
        }
        public void onClosed() { }
    }

    @Test public void duplicateDecodedKeysFailClosedOnAndroidParser() throws Exception {
        String[] duplicates = {
            "{\"type\":\"ack\",\"ok\":false,\"ok\":true}",
            "{\"type\":\"hello\",\"inputAvailable\":false,\"inputAvailable\":true}",
            "{\"type\":\"ack\",\"ok\":false,\"o\\u006b\":true}",
            "{\"type\":\"hello\",\"inputAvailable\":false,\"input\\u0041vailable\":true}",
            "{\"capabilities\":{\"nodeClick\":false,\"node\\u0043lick\":true}}",
            "{\"😀\":false,\"\\ud83d\\ude00\":true}",
            "{\"a\\n\":false,\"a\\u000a\":true}"
        };
        HeldCertificate certificate = certificate();
        try (MockWebServer server = server(certificate)) {
            for (String payload : duplicates) {
                sendOnOpen(server, payload);
                Events events = new Events();
                PinnedSocket socket = new PinnedSocket(pairing(server, certificate), events);
                try {
                    socket.connect();
                    assertTrue("Ambiguous JSON was not rejected", events.failed.await(5, TimeUnit.SECONDS));
                    assertFalse("Malformed JSON cannot be retried", events.retryable);
                    assertEquals("Ambiguous message reached application code", 0, events.delivered.get());
                    assertTrue("Production callbacks must use Android's main Looper", events.callbackOnMain);
                } finally { socket.close(); }
            }
        }
    }

    @Test public void sameKeyInSeparateObjectsAndEscapedValuesRemainValid() throws Exception {
        HeldCertificate certificate = certificate();
        try (MockWebServer server = server(certificate)) {
            sendOnOpen(server, "{\"ok\":true,\"nested\":{\"ok\":false},\"array\":[{\"ok\":true},{\"ok\":false}],\"o\\u0062ject\":\"\\\"\\\\\\/\\b\\f\\n\\r\\t\\u0041\"}");
            Events events = new Events();
            PinnedSocket socket = new PinnedSocket(pairing(server, certificate), events);
            try {
                socket.connect();
                assertTrue("Valid JSON did not reach application code", events.received.await(5, TimeUnit.SECONDS));
                assertEquals(1, events.failed.getCount());
                assertTrue(events.callbackOnMain);
                assertTrue(events.message.getBoolean("ok"));
                assertFalse(events.message.getJSONObject("nested").getBoolean("ok"));
                assertEquals(2, events.message.getJSONArray("array").length());
                assertEquals("\"\\/\b\f\n\r\tA", events.message.getString("object"));
            } finally { socket.close(); }
        }
    }

    private static HeldCertificate certificate() {
        return new HeldCertificate.Builder().commonName("Sofatap test receiver")
            .addSubjectAlternativeName("127.0.0.1").build();
    }
    private static MockWebServer server(HeldCertificate certificate) throws Exception {
        MockWebServer server = new MockWebServer();
        server.useHttps(new HandshakeCertificates.Builder().heldCertificate(certificate).build().sslSocketFactory(), false);
        server.start(InetAddress.getByName("127.0.0.1"), 0);
        return server;
    }
    private static Pairing pairing(MockWebServer server, HeldCertificate certificate) throws Exception {
        byte[] digest = MessageDigest.getInstance("SHA-256").digest(certificate.certificate().getEncoded());
        StringBuilder fingerprint = new StringBuilder();
        for (byte value : digest) fingerprint.append(String.format(java.util.Locale.ROOT, "%02x", value & 255));
        return Pairing.parse("sofatap://pair?host=127.0.0.1&port=" + server.getPort() + "&token=" + TOKEN + "&fingerprint=" + fingerprint);
    }
    private static void sendOnOpen(MockWebServer server, String payload) {
        server.enqueue(new MockResponse().withWebSocketUpgrade(new WebSocketListener() {
            @Override public void onOpen(WebSocket socket, Response response) { socket.send(payload); }
        }));
    }
}
