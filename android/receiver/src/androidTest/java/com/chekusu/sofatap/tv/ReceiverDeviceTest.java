package com.chekusu.sofatap.tv;

import android.app.*;
import android.content.*;
import android.graphics.Rect;
import android.os.*;
import android.view.WindowManager;
import android.widget.Switch;
import androidx.test.ext.junit.runners.AndroidJUnit4;
import androidx.test.platform.app.InstrumentationRegistry;
import com.chekusu.sofatap.tv.input.InputBridge;
import org.json.JSONObject;
import org.junit.*;
import org.junit.runner.RunWith;
import java.io.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.*;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicReference;
import static org.junit.Assert.*;

/** Runs only on an explicitly opted-in disposable emulator, never on a household TV. */
@RunWith(AndroidJUnit4.class)
public final class ReceiverDeviceTest {
    private Instrumentation instrumentation;
    private UiAutomation automation;
    private Context context;
    private boolean automaticUpdatePreference;
    interface Checked<T> { T call() throws Exception; }
    @Before public void emulatorOnly() {
        instrumentation = InstrumentationRegistry.getInstrumentation(); context = instrumentation.getTargetContext();
        Assume.assumeTrue("Only the owned headless emulator is allowed",
            "yes".equals(InstrumentationRegistry.getArguments().getString("disposableEmulator")) &&
            (Build.FINGERPRINT.contains("generic") || Build.MODEL.contains("sdk")));
        automation = instrumentation.getUiAutomation(UiAutomation.FLAG_DONT_SUPPRESS_ACCESSIBILITY_SERVICES);
        automaticUpdatePreference = context.getSharedPreferences("receiver_updates", Context.MODE_PRIVATE).getBoolean("automatic", true);
        ReceiverUpdates.get(context).setAutomatic(false); // No public update requests from deterministic input fixtures.
    }
    @After public void restoreUpdatePreference() {
        if (context != null && automation != null) context.getSharedPreferences("receiver_updates", Context.MODE_PRIVATE).edit().putBoolean("automatic", automaticUpdatePreference).commit();
    }
    private <T> T main(Checked<T> operation) throws Exception {
        AtomicReference<T> value = new AtomicReference<>(); AtomicReference<Exception> error = new AtomicReference<>();
        instrumentation.runOnMainSync(() -> { try { value.set(operation.call()); } catch (Exception e) { error.set(e); } });
        if (error.get() != null) throw error.get(); return value.get();
    }
    private String shell(String command) throws IOException {
        try (ParcelFileDescriptor fd = automation.executeShellCommand(command);
             FileInputStream input = new FileInputStream(fd.getFileDescriptor()); ByteArrayOutputStream output = new ByteArrayOutputStream()) {
            byte[] buffer = new byte[2048]; int count; while ((count = input.read(buffer)) >= 0) output.write(buffer, 0, count);
            return output.toString("UTF-8").trim();
        }
    }
    private void until(Checked<Boolean> condition) throws Exception {
        long deadline = SystemClock.elapsedRealtime() + 8000;
        while (!condition.call() && SystemClock.elapsedRealtime() < deadline) SystemClock.sleep(80);
        assertTrue("Timed out waiting for an observable Android state", condition.call());
    }
    private JSONObject snapshot() throws Exception { return main(() -> InputBridge.snapshot(context)); }
    private JSONObject input(String action, double x, double y) throws Exception { return main(() -> InputBridge.perform(context, action, x, y)); }
    private void moveTo(int x, int y) throws Exception {
        JSONObject position = input("move", 0, 0); assertTrue(position.toString(), position.getBoolean("ok"));
        double dx = x - position.getDouble("x"), dy = y - position.getDouble("y");
        while (Math.abs(dx) > 0.1 || Math.abs(dy) > 0.1) {
            double stepX = Math.max(-400, Math.min(400, dx)), stepY = Math.max(-400, Math.min(400, dy));
            JSONObject moved = input("move", stepX, stepY); assertTrue(moved.toString(), moved.getBoolean("ok")); dx -= stepX; dy -= stepY;
        }
    }
    @Test public void strictProtocolUsesAndroidJsonProvider() throws Exception {
        String base = "{\"id\":\"11111111-1111-4111-8111-111111111111\",\"type\":\"click\"}";
        assertEquals("click", TVProtocol.parse(base).type());
        for (String invalid : new String[]{"\uFEFF" + base, base.replace("{", "{/*comment*/"), base.replace("click", "cl\\ick"), base.replace("\"type\"", "'type'"), base.replace("}", ",\"type\":\"ping\"}"), base + "#comment"}) {
            try { TVProtocol.parse(invalid); fail("Lenient JSON accepted"); } catch (IllegalArgumentException expected) { }
        }
    }
    @Test public void identityIsEncryptedAndSurvivesRestart() throws Exception {
        ReceiverIdentity first = new ReceiverIdentity(context); String fingerprint = first.fingerprint();
        String marker = PairingAuthority.hash(PairingAuthority.randomToken());
        try {
            first.saveDigest(marker); ReceiverIdentity second = new ReceiverIdentity(context);
            assertEquals(fingerprint, second.fingerprint()); assertEquals(marker, second.pairedDigest());
            byte[] bytes = Files.readAllBytes(new File(context.getNoBackupFilesDir(), "receiver-identity.enc").toPath());
            String raw = new String(bytes, StandardCharsets.ISO_8859_1);
            assertFalse(raw.contains(marker)); assertFalse(raw.contains("PRIVATE KEY"));
            assertTrue(first.certificate.certificate().getExtendedKeyUsage().contains("1.3.6.1.5.5.7.3.1"));
        } finally { first.saveDigest(null); }
    }
    private Context isolatedIdentityContext() throws Exception {
        File directory = Files.createTempDirectory(context.getCacheDir().toPath(), "identity-test-").toFile();
        return new ContextWrapper(context) { @Override public File getNoBackupFilesDir() { return directory; } };
    }
    private void removeIdentityFixture(Context fixture) {
        File[] files = fixture.getNoBackupFilesDir().listFiles();
        if (files != null) for (File file : files) file.delete();
        fixture.getNoBackupFilesDir().delete();
    }
    @Test public void encryptedIdentityPreservesPairingAcrossAdapterChurnOfflineAndRestoration() throws Exception {
        Context fixture = isolatedIdentityContext(); long now = System.currentTimeMillis();
        List<String> original = Arrays.asList("192.168.1.20", "10.0.0.20");
        try {
            ReceiverIdentity first = new ReceiverIdentity(fixture, original, now);
            String marker = PairingAuthority.hash(PairingAuthority.randomToken()); first.saveDigest(marker);
            File profile = new File(fixture.getNoBackupFilesDir(), "receiver-identity.enc");
            byte[] encrypted = Files.readAllBytes(profile.toPath());
            for (List<String> current : Arrays.asList(Arrays.asList("10.0.0.20", "192.168.1.20"),
                    Arrays.asList("192.168.1.20", "10.0.0.20", "10.8.0.20"),
                    Collections.singletonList("192.168.1.20"), Collections.<String>emptyList(), original)) {
                ReceiverIdentity restored = new ReceiverIdentity(fixture, current, now);
                assertEquals(first.fingerprint(), restored.fingerprint()); assertEquals(marker, restored.pairedDigest());
                assertFalse(restored.addresses.contains("10.8.0.20"));
                assertTrue(current.containsAll(restored.addresses));
                assertArrayEquals("Restoration must not rewrite the encrypted pairing", encrypted, Files.readAllBytes(profile.toPath()));
            }
            ReceiverIdentity replaced = new ReceiverIdentity(fixture, Arrays.asList("192.168.1.21", "10.0.0.20"), now);
            assertNotEquals(first.fingerprint(), replaced.fingerprint()); assertNull(replaced.pairedDigest());
        } finally { removeIdentityFixture(fixture); }
    }
    @Test public void expiredIdentityWaitsOfflineThenRequiresNewEnrollment() throws Exception {
        Context fixture = isolatedIdentityContext(); long now = System.currentTimeMillis();
        List<String> addresses = Collections.singletonList("192.168.1.20");
        try {
            ReceiverIdentity expired = new ReceiverIdentity(fixture, addresses, now - TimeUnit.DAYS.toMillis(91));
            expired.saveDigest(PairingAuthority.hash(PairingAuthority.randomToken()));
            File profile = new File(fixture.getNoBackupFilesDir(), "receiver-identity.enc");
            byte[] original = Files.readAllBytes(profile.toPath());
            try { new ReceiverIdentity(fixture, Collections.emptyList(), now); fail("Expired offline identity was accepted"); }
            catch (IOException expected) { assertEquals("no_private_network", expected.getMessage()); }
            assertArrayEquals(original, Files.readAllBytes(profile.toPath()));
            ReceiverIdentity fresh = new ReceiverIdentity(fixture, addresses, now);
            assertNotEquals(expired.fingerprint(), fresh.fingerprint()); assertNull(fresh.pairedDigest());
        } finally { removeIdentityFixture(fixture); }
    }
    @Test public void corruptedEncryptedIdentityIsNeverSilentlyReplacedEvenOffline() throws Exception {
        Context fixture = isolatedIdentityContext(); long now = System.currentTimeMillis();
        List<String> addresses = Collections.singletonList("192.168.1.20");
        try {
            new ReceiverIdentity(fixture, addresses, now);
            File profile = new File(fixture.getNoBackupFilesDir(), "receiver-identity.enc");
            byte[] corrupted = Files.readAllBytes(profile.toPath()); corrupted[corrupted.length - 1] ^= 1;
            Files.write(profile.toPath(), corrupted);
            for (List<String> current : Arrays.asList(addresses, Collections.<String>emptyList())) {
                boolean rejected = false;
                try { new ReceiverIdentity(fixture, current, now); } catch (Exception expected) { rejected = true; }
                assertTrue("Corruption must remain visible", rejected);
                assertArrayEquals(corrupted, Files.readAllBytes(profile.toPath()));
            }
        } finally { removeIdentityFixture(fixture); }
    }
    @Test public void startedServiceRecoversAfterOfflineWithoutReenrollmentAndExplicitStopStaysStopped() throws Exception {
        MainActivity activity = (MainActivity) instrumentation.startActivitySync(new Intent(context, MainActivity.class).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
        try {
            main(() -> { context.startForegroundService(new Intent(context, ReceiverService.class)); return null; });
            until(() -> ReceiverService.instance != null && ReceiverService.instance.server != null);
            ReceiverService service = ReceiverService.instance;
            List<String> addresses = new ArrayList<>(service.identity.addresses);
            String fingerprint = service.identity.fingerprint();
            String token = service.authority.authorize(service.authority.newPairing()).replacementToken();
            String digest = PairingAuthority.hash(token);
            byte[] encrypted = Files.readAllBytes(new File(context.getNoBackupFilesDir(), "receiver-identity.enc").toPath());
            main(() -> { service.addressSource = Collections::emptyList; service.requestRefresh(); return null; });
            until(() -> service.server == null && "no_private_network".equals(service.error));
            assertEquals(fingerprint, service.identity.fingerprint()); assertEquals(digest, service.identity.pairedDigest());
            assertTrue(service.identity.addresses.isEmpty());
            main(() -> { service.addressSource = () -> addresses; service.requestRefresh(); return null; });
            until(() -> service.server != null && service.error == null);
            assertEquals(fingerprint, service.identity.fingerprint()); assertTrue(service.authority.authorize(token).allowed());
            assertArrayEquals(encrypted, Files.readAllBytes(new File(context.getNoBackupFilesDir(), "receiver-identity.enc").toPath()));
            main(() -> { context.stopService(new Intent(context, ReceiverService.class)); return null; });
            until(() -> ReceiverService.instance == null);
            main(() -> { service.requestRefresh(); return null; });
            SystemClock.sleep(500);
            assertNull(ReceiverService.instance); assertNull(service.server);
            service.identity.saveDigest(null);
        } finally { main(() -> { context.stopService(new Intent(context, ReceiverService.class)); activity.finish(); return null; }); }
    }
    @Test public void nativePairingProtectsOnlyVisibleCredentials() throws Exception {
        ReceiverStartup preferences = new ReceiverStartup(context);
        preferences.initializeFromVisibleLaunch(); preferences.setEnabled(false); preferences.setRunRequested(false);
        main(() -> { ReceiverStartup.stop(context); return null; }); until(() -> ReceiverService.instance == null);
        MainActivity activity = (MainActivity) instrumentation.startActivitySync(new Intent(context, MainActivity.class).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
        try {
            until(() -> main(() -> activity.getWindow().getDecorView().getWidth() > 0));
            assertFalse(main(() -> (activity.getWindow().getAttributes().flags & WindowManager.LayoutParams.FLAG_SECURE) != 0));
            main(() -> { context.startForegroundService(new Intent(context, ReceiverService.class)); return null; });
            until(() -> ReceiverService.instance != null && ReceiverService.instance.server != null);
            until(() -> main(() -> (activity.getWindow().getAttributes().flags & WindowManager.LayoutParams.FLAG_SECURE) != 0));
            assertTrue(main(() -> ReceiverService.instance.pairingUri(ReceiverService.instance.identity.addresses.get(0)).startsWith("sofatap://tv?")));
        } finally { main(() -> { context.stopService(new Intent(context, ReceiverService.class)); activity.finish(); return null; }); }
    }
    @Test public void startupDefaultNativeToggleAndStopSurviveActivityRecreation() throws Exception {
        main(() -> { ReceiverStartup.stop(context); return null; }); until(() -> ReceiverService.instance == null);
        context.getSharedPreferences(ReceiverStartup.PREFERENCES, Context.MODE_PRIVATE).edit().clear().commit();
        MainActivity activity = (MainActivity) instrumentation.startActivitySync(new Intent(context, MainActivity.class).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
        try {
            until(() -> ReceiverService.instance != null && ReceiverService.instance.server != null);
            final MainActivity first = activity;
            assertTrue(main(() -> ((Switch) first.findViewById(R.id.auto_start)).isChecked()));
            String fingerprint = ReceiverService.instance.identity.fingerprint();
            main(() -> { ((Switch) first.findViewById(R.id.auto_start)).performClick(); return null; });
            assertFalse(new ReceiverStartup(context).enabled());
            assertNotNull("Changing the boot preference must not terminate this connection", ReceiverService.instance.server);
            main(() -> { ReceiverStartup.stop(context); first.finish(); return null; }); until(() -> ReceiverService.instance == null);
            activity = (MainActivity) instrumentation.startActivitySync(new Intent(context, MainActivity.class).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
            final MainActivity second = activity;
            assertFalse(main(() -> ((Switch) second.findViewById(R.id.auto_start)).isChecked()));
            SystemClock.sleep(700);
            assertNull("Opening the screen must not undo explicit Stop", ReceiverService.instance);
            main(() -> { ((Switch) second.findViewById(R.id.auto_start)).performClick(); return null; });
            until(() -> ReceiverService.instance != null && ReceiverService.instance.server != null);
            assertEquals("Startup must preserve encrypted identity", fingerprint, ReceiverService.instance.identity.fingerprint());
            assertTrue(new ReceiverStartup(context).enabled());
            main(() -> { context.startService(new Intent(context, ReceiverService.class).setAction("stop")); return null; });
            until(() -> ReceiverService.instance == null);
            assertFalse(new ReceiverStartup(context).runRequested());
        } finally {
            final MainActivity last = activity;
            main(() -> { ReceiverStartup.stop(context); last.finish(); return null; });
        }
    }
    @Test public void bootAndUpdateRespectOptOutStopAndPlatformDenial() throws Exception {
        final String name = "startup-test-" + UUID.randomUUID();
        class RecordingContext extends ContextWrapper {
            int starts; boolean denied;
            RecordingContext() { super(context); }
            @Override public SharedPreferences getSharedPreferences(String ignored, int mode) {
                return context.getSharedPreferences(name, mode);
            }
            @Override public ComponentName startForegroundService(Intent service) {
                assertEquals(ReceiverService.class.getName(), service.getComponent().getClassName());
                if (denied) throw new IllegalStateException("simulated OEM restriction");
                starts++; return service.getComponent();
            }
            @Override public boolean stopService(Intent service) { return true; }
        }
        RecordingContext fixture = new RecordingContext(); StartupReceiver receiver = new StartupReceiver();
        try {
            receiver.onReceive(fixture, new Intent(Intent.ACTION_BOOT_COMPLETED)); assertEquals(0, fixture.starts);
            ReceiverStartup initial = new ReceiverStartup(fixture); initial.initializeFromVisibleLaunch();
            assertTrue(initial.enabled());
            receiver.onReceive(fixture, new Intent(Intent.ACTION_LOCKED_BOOT_COMPLETED)); assertEquals(0, fixture.starts);
            receiver.onReceive(fixture, new Intent("unrelated")); assertEquals(0, fixture.starts);
            receiver.onReceive(fixture, new Intent(Intent.ACTION_BOOT_COMPLETED)); assertEquals(1, fixture.starts);
            initial.setEnabled(false);
            new ReceiverStartup(fixture).initializeFromVisibleLaunch();
            receiver.onReceive(fixture, new Intent(Intent.ACTION_BOOT_COMPLETED));
            receiver.onReceive(fixture, new Intent(Intent.ACTION_MY_PACKAGE_REPLACED)); assertEquals(1, fixture.starts);
            assertFalse("Opening again must retain opt-out", new ReceiverStartup(fixture).enabled());
            initial.setEnabled(true); ReceiverStartup.stop(fixture);
            receiver.onReceive(fixture, new Intent(Intent.ACTION_MY_PACKAGE_REPLACED)); assertEquals(1, fixture.starts);
            receiver.onReceive(fixture, new Intent(Intent.ACTION_BOOT_COMPLETED)); assertEquals(2, fixture.starts);
            receiver.onReceive(fixture, new Intent(Intent.ACTION_MY_PACKAGE_REPLACED)); assertEquals(3, fixture.starts);
            fixture.denied = true;
            receiver.onReceive(fixture, new Intent(Intent.ACTION_BOOT_COMPLETED));
            assertTrue(new ReceiverStartup(fixture).blocked()); assertEquals(3, fixture.starts);
            fixture.denied = false; assertTrue(ReceiverStartup.start(fixture)); assertEquals(4, fixture.starts);
            assertFalse(new ReceiverStartup(fixture).blocked());
        } finally { context.deleteSharedPreferences(name); }
    }
    @Test public void realAccessibilityClickScrollAndDisconnectOnTvEmulator() throws Exception {
        String previous = shell("settings get secure enabled_accessibility_services");
        String enabled = shell("settings get secure accessibility_enabled");
        InputFixtureActivity fixture = null;
        try {
            shell("settings put secure enabled_accessibility_services com.chekusu.sofatap.tv/.input.SofatapAccessibilityService");
            shell("settings put secure accessibility_enabled 1");
            until(() -> snapshot().optBoolean("inputAvailable"));
            assertTrue("Fixture must be the TV system image", context.getPackageManager().hasSystemFeature("android.hardware.type.television"));
            fixture = (InputFixtureActivity) instrumentation.startActivitySync(new Intent(context, InputFixtureActivity.class).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
            final InputFixtureActivity target = fixture;
            until(() -> main(() -> target.click.getWidth() > 0 && target.hasWindowFocus()));
            JSONObject localStatus = snapshot();
            assertFalse("Acknowledgments must not query another app's accessibility tree", localStatus.has("activeWindowReadable"));
            assertFalse(localStatus.has("activeWindowProtected"));
            assertTrue(localStatus.getInt("displayWidth") > 0);
            SystemClock.sleep(300);
            Rect button = main(() -> { Rect r = new Rect(); target.click.getGlobalVisibleRect(r); return r; });
            moveTo(button.centerX(), button.centerY());
            JSONObject click = input("click", 0, 0); assertTrue(click.toString(), click.getBoolean("ok"));
            until(() -> main(() -> target.clicks == 1));
            Rect area = main(() -> { Rect r = new Rect(); target.scroll.getGlobalVisibleRect(r); return r; });
            moveTo(area.centerX(), area.centerY());
            JSONObject scroll = input("scroll", 0, 80); assertTrue(scroll.toString(), scroll.getBoolean("ok"));
            until(() -> main(() -> target.scroll.getScrollY() > 0));
            assertTrue(snapshot().getBoolean("cursorVisible"));
            main(() -> { InputBridge.disconnect(); return null; });
            assertFalse(snapshot().getBoolean("cursorVisible"));
            shell("settings put secure enabled_accessibility_services null");
            until(() -> !snapshot().optBoolean("inputAvailable"));
            assertFalse(input("click", 0, 0).getBoolean("ok"));
            assertEquals(1, (int) main(() -> target.clicks));
        } finally {
            if (fixture != null) { final Activity a = fixture; main(() -> { a.finish(); return null; }); }
            if ("null".equals(previous)) shell("settings delete secure enabled_accessibility_services");
            else shell("settings put secure enabled_accessibility_services '" + previous.replace("'", "'\\''") + "'");
            if ("null".equals(enabled)) shell("settings delete secure accessibility_enabled");
            else shell("settings put secure accessibility_enabled " + ("1".equals(enabled) ? "1" : "0"));
        }
    }
}
