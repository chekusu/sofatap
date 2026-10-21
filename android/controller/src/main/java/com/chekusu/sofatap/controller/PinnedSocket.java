package com.chekusu.sofatap.controller;

import android.os.Handler;
import android.os.Looper;
import org.json.JSONObject;
import java.net.ProtocolException;
import java.net.Proxy;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.SecureRandom;
import java.security.cert.CertificateException;
import java.security.cert.X509Certificate;
import java.util.concurrent.Executor;
import java.util.concurrent.TimeUnit;
import javax.net.ssl.SSLContext;
import javax.net.ssl.SSLException;
import javax.net.ssl.X509TrustManager;
import okhttp3.OkHttpClient;
import okhttp3.Request;
import okhttp3.Response;
import okhttp3.WebSocket;
import okhttp3.WebSocketListener;
import okio.ByteString;

/** One connection to one scanned TLS identity. Never installs a global trust manager. */
public final class PinnedSocket {
    public interface Listener {
        void onOpen();
        void onMessage(JSONObject message);
        void onFailure(boolean retryable);
        void onClosed();
    }

    static final int MAX_MESSAGE_BYTES = 64 * 1024;
    static final long MAX_PENDING_BYTES = 256 * 1024;
    private final Pairing pairing;
    private final Listener listener;
    private final Executor callbacks;
    private OkHttpClient client;
    private WebSocket socket;
    private boolean started;
    private boolean open;
    private boolean terminal;

    public PinnedSocket(Pairing pairing, Listener listener) {
        this(pairing, listener, command -> new Handler(Looper.getMainLooper()).post(command));
    }

    PinnedSocket(Pairing pairing, Listener listener, Executor callbacks) {
        if (pairing == null || listener == null || callbacks == null) throw new IllegalArgumentException("Missing connection configuration");
        this.pairing = pairing;
        this.listener = listener;
        this.callbacks = callbacks;
    }

    public synchronized void connect() {
        if (started || terminal) return;
        started = true;
        try {
            X509TrustManager trust = trustManager(pairing.fingerprint);
            SSLContext tls = SSLContext.getInstance("TLS");
            tls.init(null, new X509TrustManager[] {trust}, new SecureRandom());
            client = new OkHttpClient.Builder()
                .sslSocketFactory(tls.getSocketFactory(), trust)
                // Retain OkHttp's SAN hostname verification in addition to the leaf pin.
                .followRedirects(false).followSslRedirects(false)
                .retryOnConnectionFailure(false).proxy(Proxy.NO_PROXY)
                .connectTimeout(8, TimeUnit.SECONDS).readTimeout(0, TimeUnit.SECONDS)
                .writeTimeout(8, TimeUnit.SECONDS).pingInterval(15, TimeUnit.SECONDS)
                .build();
            Request request = new Request.Builder().url(pairing.endpoint())
                .header("Authorization", "Bearer " + pairing.token).build();
            socket = client.newWebSocket(request, new WebSocketListener() {
                @Override public void onOpen(WebSocket webSocket, Response response) {
                    synchronized (PinnedSocket.this) {
                        if (terminal) { webSocket.cancel(); return; }
                        open = true;
                    }
                    postActive(listener::onOpen);
                }
                @Override public void onMessage(WebSocket webSocket, String text) {
                    // OkHttp delivers complete messages. Reject oversized content before parsing it.
                    if (text.length() > MAX_MESSAGE_BYTES || text.getBytes(StandardCharsets.UTF_8).length > MAX_MESSAGE_BYTES) {
                        fail(false); return;
                    }
                    try {
                        JsonSyntax.check(text);
                        JSONObject object = new JSONObject(text);
                        postActive(() -> listener.onMessage(object));
                    } catch (Exception invalidMessage) { fail(false); }
                }
                @Override public void onMessage(WebSocket webSocket, ByteString bytes) { fail(false); }
                @Override public void onClosing(WebSocket webSocket, int code, String reason) {
                    // No payloads or server-provided reason strings leave this transport.
                    webSocket.close(code, null);
                }
                @Override public void onClosed(WebSocket webSocket, int code, String reason) {
                    if (code == 1002 || code == 1003 || code == 1007 || code == 1008 || code == 1009) fail(false);
                    else finishClosed();
                }
                @Override public void onFailure(WebSocket webSocket, Throwable error, Response response) {
                    // A pinned receiver permits one controller at a time. Its old socket may
                    // still be closing when the foreground session reconnects, producing 409.
                    boolean retryable = !(error instanceof SSLException) && (response != null
                        ? response.code() == 409 : !(error instanceof ProtocolException));
                    fail(retryable);
                }
            });
        } catch (Exception invalidConfiguration) { fail(false); }
    }

    public synchronized boolean send(JSONObject message) {
        if (!open || terminal || socket == null || message == null) return false;
        String text = message.toString();
        if (text == null || text.length() > MAX_MESSAGE_BYTES) return false;
        int bytes = text.getBytes(StandardCharsets.UTF_8).length;
        if (bytes > MAX_MESSAGE_BYTES) return false;
        if (socket.queueSize() + bytes > MAX_PENDING_BYTES) {
            // Abandon a stalled connection instead of replaying stale clicks or text later.
            fail(true); return false;
        }
        boolean accepted = socket.send(text);
        if (!accepted) fail(true);
        return accepted;
    }

    public void close() { finishClosed(); }

    private void postActive(Runnable action) {
        callbacks.execute(() -> { synchronized (PinnedSocket.this) { if (!terminal) action.run(); } });
    }

    private void fail(boolean retryable) {
        synchronized (this) {
            if (terminal) return;
            terminal = true;
            dispose();
        }
        callbacks.execute(() -> listener.onFailure(retryable));
    }

    private void finishClosed() {
        synchronized (this) {
            if (terminal) return;
            terminal = true;
            dispose();
        }
        callbacks.execute(listener::onClosed);
    }

    private void dispose() {
        open = false;
        if (socket != null) { socket.cancel(); socket = null; }
        if (client != null) {
            client.connectionPool().evictAll();
            client.dispatcher().executorService().shutdown();
        }
    }

    static X509TrustManager trustManager(String fingerprint) {
        if (fingerprint == null || !fingerprint.matches("[0-9a-fA-F]{64}")) throw new IllegalArgumentException("Invalid certificate identity");
        byte[] expected = new byte[32];
        for (int i = 0; i < expected.length; i++) expected[i] = (byte) Integer.parseInt(fingerprint.substring(i * 2, i * 2 + 2), 16);
        return new X509TrustManager() {
            @Override public X509Certificate[] getAcceptedIssuers() { return new X509Certificate[0]; }
            @Override public void checkClientTrusted(X509Certificate[] chain, String authType) throws CertificateException {
                throw new CertificateException("Client certificates are not supported");
            }
            @Override public void checkServerTrusted(X509Certificate[] chain, String authType) throws CertificateException {
                if (chain == null || chain.length == 0) throw new CertificateException("Missing certificate");
                chain[0].checkValidity();
                try {
                    byte[] actual = MessageDigest.getInstance("SHA-256").digest(chain[0].getEncoded());
                    if (!MessageDigest.isEqual(expected, actual)) throw new CertificateException("Certificate identity mismatch");
                } catch (CertificateException error) { throw error; }
                catch (Exception invalidCertificate) { throw new CertificateException("Certificate verification failed"); }
            }
        };
    }

    // Android's JSONObject reader accepts comments, unquoted strings, trailing data and
    // duplicate keys (last value wins). Reject ambiguous messages before building the model.
    private static final class JsonSyntax {
        private final String text;
        private int cursor;
        private JsonSyntax(String text) { this.text = text; }
        static void check(String text) {
            JsonSyntax parser = new JsonSyntax(text);
            parser.space();
            if (parser.peek() != '{') throw new IllegalArgumentException();
            parser.value(0); parser.space();
            if (parser.cursor != text.length()) throw new IllegalArgumentException();
        }
        private char peek() { return cursor < text.length() ? text.charAt(cursor) : '\0'; }
        private void space() { while (cursor < text.length() && " \t\r\n".indexOf(text.charAt(cursor)) >= 0) cursor++; }
        private void expect(char c) { if (peek() != c) throw new IllegalArgumentException(); cursor++; }
        private void value(int depth) {
            if (depth > 32) throw new IllegalArgumentException();
            space(); char c = peek();
            if (c == '{') {
                cursor++; space(); if (peek() == '}') { cursor++; return; }
                java.util.Set<String> keys = new java.util.HashSet<>();
                while (true) {
                    space();
                    // A Unicode escape cannot hide a duplicate decoded key.
                    if (!keys.add(string())) throw new IllegalArgumentException();
                    space(); expect(':'); value(depth + 1); space();
                    if (peek() == '}') { cursor++; return; }
                    expect(',');
                }
            } else if (c == '[') {
                cursor++; space(); if (peek() == ']') { cursor++; return; }
                while (true) {
                    value(depth + 1); space();
                    if (peek() == ']') { cursor++; return; }
                    expect(',');
                }
            } else if (c == '"') string();
            else if (c == 't') literal("true");
            else if (c == 'f') literal("false");
            else if (c == 'n') literal("null");
            else number();
        }
        private void literal(String literal) {
            if (!text.startsWith(literal, cursor)) throw new IllegalArgumentException();
            cursor += literal.length();
        }
        private boolean digit() { return peek() >= '0' && peek() <= '9'; }
        private void number() {
            if (peek() == '-') cursor++;
            if (peek() == '0') cursor++;
            else { if (!digit()) throw new IllegalArgumentException(); while (digit()) cursor++; }
            if (peek() == '.') { cursor++; if (!digit()) throw new IllegalArgumentException(); while (digit()) cursor++; }
            if (peek() == 'e' || peek() == 'E') {
                cursor++; if (peek() == '+' || peek() == '-') cursor++;
                if (!digit()) throw new IllegalArgumentException(); while (digit()) cursor++;
            }
        }
        private String string() {
            expect('"');
            StringBuilder decoded = new StringBuilder();
            while (cursor < text.length()) {
                char c = text.charAt(cursor++);
                if (c == '"') return decoded.toString();
                if (c < 0x20) throw new IllegalArgumentException();
                if (c == '\\') {
                    if (cursor >= text.length()) throw new IllegalArgumentException();
                    char escape = text.charAt(cursor++);
                    if (escape == 'u') {
                        int code = 0;
                        for (int i = 0; i < 4; i++) {
                            if (cursor >= text.length()) throw new IllegalArgumentException();
                            char hex = text.charAt(cursor++);
                            if ("0123456789abcdefABCDEF".indexOf(hex) < 0) throw new IllegalArgumentException();
                            code = code * 16 + Character.digit(hex, 16);
                        }
                        decoded.append((char) code);
                    } else {
                        decoded.append(switch (escape) {
                            case '"', '\\', '/' -> escape;
                            case 'b' -> '\b'; case 'f' -> '\f'; case 'n' -> '\n';
                            case 'r' -> '\r'; case 't' -> '\t';
                            default -> throw new IllegalArgumentException();
                        });
                    }
                } else decoded.append(c);
            }
            throw new IllegalArgumentException();
        }
    }
}
