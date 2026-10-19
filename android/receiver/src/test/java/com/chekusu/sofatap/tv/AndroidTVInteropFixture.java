package com.chekusu.sofatap.tv;

import okhttp3.tls.HeldCertificate;
import org.json.JSONArray;
import org.json.JSONObject;
import javax.net.ssl.KeyManagerFactory;
import javax.net.ssl.SSLContext;
import java.net.Inet4Address;
import java.net.InetAddress;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.nio.file.attribute.PosixFilePermissions;
import java.security.KeyStore;
import java.security.MessageDigest;
import java.util.*;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicReference;
import java.util.function.BooleanSupplier;

/** Short-lived interop fixture. Counts actions only; never accesses desktop/device input. */
public final class AndroidTVInteropFixture {
    public static void main(String[] args) throws Exception {
        if (args.length != 2) throw new IllegalArgumentException("Expected bind IPv4 and private temporary directory");
        InetAddress bind = InetAddress.getByName(args[0]);
        if (!(bind instanceof Inet4Address) || !bind.isSiteLocalAddress() || bind.isLoopbackAddress())
            throw new IllegalArgumentException("A private LAN IPv4 is required by the production pairing parser");
        Path directory = Path.of(args[1]).toAbsolutePath();
        if (!Files.isDirectory(directory)) throw new IllegalArgumentException("Caller must create private temporary directory");
        Files.setPosixFilePermissions(directory, PosixFilePermissions.fromString("rwx------"));
        HeldCertificate certificate = ReceiverCertificate.generate(Collections.singletonList(bind.getHostAddress()));
        KeyStore keys = KeyStore.getInstance(KeyStore.getDefaultType()); keys.load(null);
        keys.setKeyEntry("test", certificate.keyPair().getPrivate(), "test-only".toCharArray(),
            new java.security.cert.Certificate[]{certificate.certificate()});
        KeyManagerFactory manager = KeyManagerFactory.getInstance(KeyManagerFactory.getDefaultAlgorithm());
        manager.init(keys, "test-only".toCharArray());
        SSLContext tls = SSLContext.getInstance("TLS"); tls.init(manager.getKeyManagers(), null, null);
        // Simulate durable storage across receiver object destruction without writing
        // a credential or key outside this private, short-lived fixture process.
        AtomicReference<String> pairedDigest = new AtomicReference<>();
        PairingAuthority authority = new PairingAuthority(null, System::currentTimeMillis, pairedDigest::set);
        String bootstrap = authority.newPairing(); CountingInput input = new CountingInput(directory);
        ReceiverServer server = new ReceiverServer(tls, bind, 0, authority, input, "Sofatap test fixture");
        final int port = server.port();
        AtomicReference<ReceiverServer> activeServer = new AtomicReference<>(server);
        String pin = PairingAuthority.hex(MessageDigest.getInstance("SHA-256").digest(certificate.certificate().getEncoded()));
        String qr = "sofatap://tv?host=" + bind.getHostAddress() + "&port=" + server.port()
            + "&token=" + bootstrap + "&fingerprint=" + pin;
        Runtime.getRuntime().addShutdownHook(new Thread(() -> {
            ReceiverServer active = activeServer.get(); if (active != null) active.close();
        }, "Sofatap-fixture-cleanup"));
        server.start();
        int serverStarts = 1;
        try {
            write(directory.resolve("stats.json"), input.stats(authority, server, serverStarts));
            write(directory.resolve("fixture.json"), new JSONObject().put("qr", qr)
                .put("host", bind.getHostAddress()).put("port", server.port()).put("pin", pin));
            long until = System.nanoTime() + TimeUnit.SECONDS.toNanos(90);
            while (!Files.exists(directory.resolve("stop")) && System.nanoTime() < until) {
                // Close a real TLS connection after the fixture applied an action,
                // but before ReceiverServer can acknowledge it. The phone must
                // discard both that ambiguous action and its queued motion.
                if (server != null && input.awaitingAck.get() && Files.deleteIfExists(directory.resolve("stop-after-action"))) {
                    server.close(); server = null; activeServer.set(null);
                }
                if (server == null && Files.deleteIfExists(directory.resolve("restart-server"))) {
                    authority = new PairingAuthority(pairedDigest.get(), System::currentTimeMillis, pairedDigest::set);
                    server = new ReceiverServer(tls, bind, port, authority, input, "Sofatap test fixture");
                    activeServer.set(server); server.start(); serverStarts++;
                }
                write(directory.resolve("stats.json"), input.stats(authority, server, serverStarts));
                Thread.sleep(100);
            }
        } finally {
            if (server != null) server.close();
            activeServer.set(null);
            write(directory.resolve("stats.json"), input.stats(authority, null, serverStarts));
        }
    }

    private static final class CountingInput implements ReceiverServer.Input {
        private final Path directory;
        private final List<JSONObject> actions = new ArrayList<>();
        private final AtomicInteger snapshots = new AtomicInteger(), disconnects = new AtomicInteger();
        private final AtomicBoolean awaitingAck = new AtomicBoolean();
        CountingInput(Path directory) { this.directory = directory; }
        @Override public JSONObject snapshot() throws Exception {
            snapshots.incrementAndGet(); boolean ready = !Files.exists(directory.resolve("block-input"));
            JSONObject capabilities = new JSONObject();
            for (String key : Arrays.asList("overlayCursor", "nodeClick", "scroll", "back", "home", "directionalFocus"))
                capabilities.put(key, ready);
            for (String key : Arrays.asList("text", "rawMouse", "rightClick", "drag")) capabilities.put(key, false);
            return new JSONObject().put("inputAvailable", ready)
                .put("inputStatus", ready ? "ready" : "accessibility_required").put("capabilities", capabilities)
                .put("appShortcuts", new JSONObject().put("schema", 1)
                    .put("availableApps", ready ? new JSONArray().put("youtube").put("netflix") : new JSONArray()));
        }
        @Override public JSONObject apply(TVProtocol.Action action, BooleanSupplier current) throws Exception {
            if (!current.getAsBoolean() || Files.exists(directory.resolve("block-input")))
                return new JSONObject().put("ok", false).put("code", "accessibility_required");
            JSONObject entry = new JSONObject().put("type", action.type()).put("dx", action.dx()).put("dy", action.dy());
            if (action.key() != null) entry.put("key", action.key());
            if (action.app() != null) entry.put("app", action.app());
            synchronized (actions) { actions.add(entry); }
            if (Files.deleteIfExists(directory.resolve("hold-next-action"))) {
                awaitingAck.set(true);
                try {
                    long until = System.nanoTime() + TimeUnit.SECONDS.toNanos(10);
                    while (current.getAsBoolean() && System.nanoTime() < until) Thread.sleep(10);
                    throw new IllegalStateException("Fixture deliberately withheld action acknowledgement");
                } finally { awaitingAck.set(false); }
            }
            return new JSONObject().put("ok", true);
        }
        @Override public void disconnected() { disconnects.incrementAndGet(); }
        JSONObject stats(PairingAuthority authority, ReceiverServer server, int serverStarts) throws Exception {
            JSONArray recorded;
            synchronized (actions) { recorded = new JSONArray(actions); }
            return new JSONObject().put("paired", authority.paired()).put("actions", recorded)
                .put("snapshots", snapshots.get()).put("disconnects", disconnects.get())
                .put("connected", server != null && server.connected())
                .put("serverRunning", server != null).put("serverStarts", serverStarts);
        }
    }

    private static void write(Path path, JSONObject value) throws Exception {
        Path temporary = Files.createTempFile(path.getParent(), ".sofatap-", ".json",
            PosixFilePermissions.asFileAttribute(PosixFilePermissions.fromString("rw-------")));
        try {
            Files.write(temporary, value.toString().getBytes(StandardCharsets.UTF_8));
            Files.move(temporary, path, StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING);
        } finally { Files.deleteIfExists(temporary); }
    }
}
