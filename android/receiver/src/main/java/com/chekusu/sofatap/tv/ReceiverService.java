package com.chekusu.sofatap.tv;

import android.app.*;
import android.content.*;
import android.net.*;
import android.os.*;
import com.chekusu.sofatap.tv.input.InputBridge;
import org.json.JSONObject;
import java.util.concurrent.*;
import java.util.function.BooleanSupplier;
import java.util.List;

/** User-visible foreground listener, with opt-out boot startup and no wake lock. */
public final class ReceiverService extends Service {
    static volatile ReceiverService instance;
    // Preserve the listener shutdown barrier across stop/start Service instances.
    // Waiting happens only on the setup executor, never in Android main callbacks.
    private static final ConcurrentLinkedQueue<ReceiverServer> retiringListeners = new ConcurrentLinkedQueue<>();
    private static final Object listenerSetup = new Object();
    private final Handler main = new Handler(Looper.getMainLooper());
    private final ExecutorService setup = Executors.newSingleThreadExecutor();
    private volatile boolean stopped;
    volatile ReceiverServer server;
    volatile ReceiverIdentity identity;
    volatile PairingAuthority authority;
    volatile String error;
    private volatile RemoteV2Client remote;
    private boolean starting;
    private boolean refreshPending;
    interface AddressSource { List<String> read() throws Exception; }
    volatile AddressSource addressSource = ReceiverIdentity::localAddresses;
    private ConnectivityManager connectivity;
    private ConnectivityManager.NetworkCallback networkCallback;
    private boolean networkRegistered;
    private boolean foregroundFailed;
    private final Runnable refreshNetwork = this::requestRefresh;

    @Override public void onCreate() {
        super.onCreate(); instance = this;
        NotificationManager manager = getSystemService(NotificationManager.class);
        manager.createNotificationChannel(new NotificationChannel("receiver", getString(R.string.app_name), NotificationManager.IMPORTANCE_LOW));
        Intent open = new Intent(this, MainActivity.class);
        PendingIntent pending = PendingIntent.getActivity(this, 0, open, PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
        Intent stop = new Intent(this, ReceiverService.class).setAction("stop");
        PendingIntent stopPending = PendingIntent.getService(this, 1, stop, PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
        Notification note = new Notification.Builder(this, "receiver").setSmallIcon(R.drawable.notification_icon)
            .setContentTitle("Sofatap").setContentText(getString(R.string.notification_active)).setContentIntent(pending)
            .setOngoing(true).addAction(new Notification.Action.Builder(null, getString(R.string.stop), stopPending).build()).build();
        try { startForeground(41, note); }
        catch (IllegalStateException | SecurityException denied) {
            foregroundFailed = true;
            new ReceiverStartup(this).setBlocked(true);
            stopSelf();
            return;
        }
        InputBridge.setInterruptionListener(() -> { ReceiverServer active = server; if (active != null) active.disconnectController(); });
        connectivity = getSystemService(ConnectivityManager.class);
        networkCallback = new ConnectivityManager.NetworkCallback() {
            @Override public void onAvailable(Network network) { scheduleRefresh(); }
            @Override public void onLost(Network network) { scheduleRefresh(); }
            @Override public void onLinkPropertiesChanged(Network network, LinkProperties properties) { scheduleRefresh(); }
        };
        // Remove the builder's defaults explicitly for Android 8.0/API 26 support.
        // Local-only LANs and VPN adapter changes must also refresh the SAN address set.
        NetworkRequest networks = new NetworkRequest.Builder()
            .removeCapability(NetworkCapabilities.NET_CAPABILITY_NOT_RESTRICTED)
            .removeCapability(NetworkCapabilities.NET_CAPABILITY_TRUSTED)
            .removeCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN).build();
        connectivity.registerNetworkCallback(networks, networkCallback, main);
        networkRegistered = true;
    }
    @Override public int onStartCommand(Intent intent, int flags, int startId) {
        ReceiverStartup settings = new ReceiverStartup(this);
        if (foregroundFailed) { stopSelf(); return START_NOT_STICKY; }
        if (intent != null && "stop".equals(intent.getAction())) {
            settings.setRunRequested(false); stopSelf(); return START_NOT_STICKY;
        }
        if (intent == null && !settings.runRequested()) { stopSelf(); return START_NOT_STICKY; }
        settings.setRunRequested(true); settings.setBlocked(false);
        ReceiverUpdates.get(this).serviceStarted();
        requestRefresh();
        // OS process reclamation may restore the requested listener, but explicit Stop removes it.
        return START_STICKY;
    }
    private void scheduleRefresh() {
        if (stopped) return;
        main.removeCallbacks(refreshNetwork);
        main.postDelayed(refreshNetwork, 400);
    }
    /** Main-thread entry point; network callbacks run only while the requested service exists. */
    void requestRefresh() {
        if (stopped) return;
        if (starting) { refreshPending = true; return; }
        starting = true;
        setup.execute(() -> {
            ReceiverServer candidate = null;
            try {
                if (remote == null) {
                    try {
                        RemoteV2Client created = new RemoteV2Client(new RemoteV2Identity(this));
                        synchronized (this) { if (stopped) { created.close(); return; } remote = created; }
                    } catch (Exception unavailable) { /* Remote identity failure does not disable the existing manual receiver. */ }
                }
                List<String> addresses = addressSource.read();
                if (stopped) return;
                ReceiverIdentity credentials = identity;
                if (credentials != null && !credentials.refreshAddresses(addresses, System.currentTimeMillis())) {
                    // Retire old callbacks before replacing the persisted identity.
                    closeRuntime(); identity = null; credentials = null;
                }
                if (credentials == null) credentials = new ReceiverIdentity(this, addresses, System.currentTimeMillis());
                identity = credentials;
                if (credentials.addresses.isEmpty()) {
                    closeRuntime(); error = "no_private_network"; return;
                }
                if (server != null) { error = null; return; }
                PairingAuthority auth = new PairingAuthority(credentials.pairedDigest(), SystemClock::elapsedRealtime, credentials::saveDigest);
                if (!auth.paired()) auth.newPairing();
                String name = PairingUri.deviceName(Build.MODEL);
                // Preserve the existing hello frame's 128-byte display-name contract.
                if (name.getBytes(java.nio.charset.StandardCharsets.UTF_8).length > 128) name = "Android TV";
                synchronized (listenerSetup) {
                    awaitRetiringListeners();
                    if (stopped) return;
                    candidate = new ReceiverServer(credentials.tls(), null, 53319, auth, new ReceiverServer.Input() {
                        @Override public JSONObject snapshot() throws Exception {
                            return onMain(() -> inputSnapshot());
                        }
                        @Override public JSONObject apply(TVProtocol.Action action, BooleanSupplier current) throws Exception {
                            if (action.type().startsWith("remote_")) {
                                if (stopped || !current.getAsBoolean()) return new JSONObject().put("ok", false).put("code", "session_ended");
                                RemoteV2Client controller = remote;
                                String result = controller == null ? "remote_unavailable" : switch (action.type()) {
                                    case "remote_pair_start" -> controller.startPairing(current);
                                    case "remote_pair_code" -> controller.submitCode(action.code(), current);
                                    case "remote_key" -> controller.key(action.key(), current);
                                    default -> "unsupported_action";
                                };
                                return new JSONObject().put("ok", result.equals("ok")).put("code", result);
                            }
                            return onMain(() -> {
                                if (stopped || !current.getAsBoolean()) return new JSONObject().put("ok", false).put("code", "session_ended");
                                if (action.type().startsWith("text_")) return SofatapInputMethodService.apply(ReceiverService.this, action, current);
                                if (action.type().equals("app_launch")) return InputBridge.launchApp(action.app(), current);
                                String kind = action.type();
                                if (kind.equals("key")) {
                                    kind = action.key();
                                    if (kind.equals("confirm")) kind = "focus_click";
                                    else if (!kind.equals("back") && !kind.equals("home")) kind = "focus_" + kind;
                                }
                                return InputBridge.perform(ReceiverService.this, kind, action.dx(), action.dy());
                            });
                        }
                        @Override public void disconnected() {
                            RemoteV2Client controller = remote; if (controller != null) controller.disconnected();
                            main.post(() -> {
                                SofatapInputMethodService.disconnected();
                                ReceiverServer active = server; if (active == null || !active.connected()) InputBridge.disconnect();
                            });
                        }
                    }, name);
                    synchronized (this) {
                        if (stopped) { candidate.close(); return; }
                        identity = credentials; authority = auth; server = candidate; candidate.start();
                        error = null;
                    }
                }
            } catch (Exception failure) {
                synchronized (this) {
                    if (candidate != null && server == candidate) closeRuntime();
                    else if (candidate != null) candidate.close();
                }
                error = "no_private_network".equals(failure.getMessage()) ? "no_private_network" : "start_failed";
            } finally {
                main.post(() -> {
                    starting = false;
                    if (!stopped && refreshPending) { refreshPending = false; requestRefresh(); }
                });
            }
        });
    }
    private JSONObject inputSnapshot() throws Exception {
        JSONObject legacy = InputBridge.snapshot(this);
        RemoteV2Client controller = remote;
        if (controller != null) controller.ensureConnected();
        JSONObject controls = SofatapInputMethodService.snapshot(this).put("version", 1)
            .put("navigationStatus", controller == null ? "unavailable" : controller.status());
        // Separate optional extension: existing iPhone builds strictly parse tvControls.
        return legacy.put("tvControls", controls).put("appShortcuts", InputBridge.appShortcuts());
    }
    String navigationStatus() { RemoteV2Client value = remote; return value == null ? "unavailable" : value.status(); }
    private synchronized void closeRuntime() {
        // authorize() and retire() share the authority lock, so a previous listener
        // can never save a new credential after a replacement identity is written.
        if (authority != null) authority.retire();
        authority = null;
        ReceiverServer previous = server; server = null;
        if (previous != null) {
            retiringListeners.add(previous);
            previous.close();
        }
        main.post(() -> { ReceiverServer active = server; if (active == null || !active.connected()) InputBridge.disconnect(); });
    }
    private static void awaitRetiringListeners() throws Exception {
        ReceiverServer previous;
        while ((previous = retiringListeners.peek()) != null) {
            if (!previous.awaitListenerStopped(2, TimeUnit.SECONDS))
                throw new java.io.IOException("listener_shutdown_timeout");
            retiringListeners.remove(previous);
        }
    }
    private <T> T onMain(Callable<T> action) throws Exception {
        FutureTask<T> task = new FutureTask<>(action); main.post(task);
        try { return task.get(2, TimeUnit.SECONDS); }
        finally { task.cancel(false); main.removeCallbacks(task); }
    }
    synchronized void newPairing() {
        if (authority == null || server == null || stopped) return;
        // Called by the on-TV button: revoke the previous controller first.
        server.disconnectController(); InputBridge.disconnect();
        try { authority.newPairing(); error = null; }
        catch (Exception failure) { error = "storage_failed"; ReceiverStartup.stop(this); }
    }
    synchronized String pairingUri(String address) {
        try {
            String token = authority == null ? null : authority.bootstrap();
            if (token == null || identity == null || !identity.addresses.contains(address)) return null;
            return PairingUri.create(address, 53319, token, identity.fingerprint(), Build.MODEL);
        } catch (Exception ignored) { return null; }
    }
    @Override public void onDestroy() {
        ReceiverUpdates.get(this).serviceStopped();
        synchronized (this) { stopped = true; closeRuntime(); }
        main.removeCallbacks(refreshNetwork);
        if (connectivity != null && networkRegistered) connectivity.unregisterNetworkCallback(networkCallback);
        setup.shutdownNow(); RemoteV2Client controller = remote; if (controller != null) controller.close();
        SofatapInputMethodService.disconnected(); InputBridge.setInterruptionListener(null); InputBridge.disconnect();
        if (instance == this) instance = null;
        stopForeground(STOP_FOREGROUND_REMOVE); super.onDestroy();
    }
    @Override public IBinder onBind(Intent intent) { return null; }
}
