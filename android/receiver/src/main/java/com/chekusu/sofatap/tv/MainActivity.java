package com.chekusu.sofatap.tv;

import android.Manifest;
import android.app.*;
import android.content.*;
import android.content.pm.PackageManager;
import android.graphics.*;
import android.graphics.drawable.GradientDrawable;
import android.os.*;
import android.provider.Settings;
import android.view.*;
import android.widget.*;
import com.chekusu.sofatap.tv.input.InputBridge;
import com.google.zxing.*;
import com.google.zxing.common.BitMatrix;
import org.json.JSONObject;
import java.util.*;

/** TV-native pairing and capability status. No browser or WebView. */
public final class MainActivity extends Activity {
    private static final int BACKGROUND = Color.rgb(18, 35, 34), MINT = Color.rgb(167, 237, 203), INK = Color.rgb(225, 244, 236);
    private final Handler main = new Handler(Looper.getMainLooper());
    private ImageView qr;
    private TextView qrCaption, status, help, capabilities, nativeControls;
    private Button start, pair, permission, enableIme, selectIme;
    private Switch autoStart;
    private ReceiverStartup startup;
    private ReceiverUpdates updates;
    private TextView updateStatus;
    private Button checkUpdate, installUpdate, cancelUpdate;
    private Switch autoUpdate;
    private Spinner network;
    private String renderedURI;
    private List<String> addresses = new ArrayList<>();
    private boolean active;
    private final Runnable tick = new Runnable() { @Override public void run() { if (active) { refresh(); main.postDelayed(this, 700); } } };

    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        startup = new ReceiverStartup(this); startup.initializeFromVisibleLaunch();
        getWindow().setFlags(WindowManager.LayoutParams.FLAG_SECURE, WindowManager.LayoutParams.FLAG_SECURE);
        // QR bearer credentials must not leak through screenshots/cast previews.
        LinearLayout root = new LinearLayout(this); root.setOrientation(LinearLayout.HORIZONTAL);
        root.setPadding(dp(36), dp(24), dp(36), dp(24)); root.setBackgroundColor(BACKGROUND);
        LinearLayout left = new LinearLayout(this); left.setOrientation(LinearLayout.VERTICAL); left.setGravity(Gravity.CENTER);
        LinearLayout.LayoutParams leftParams = new LinearLayout.LayoutParams(0, -1, 0.43f); leftParams.setMargins(0, 0, dp(28), 0);
        root.addView(left, leftParams);
        qr = new ImageView(this); qr.setScaleType(ImageView.ScaleType.FIT_CENTER); qr.setContentDescription(getString(R.string.qr_description));
        LinearLayout.LayoutParams qrParams = new LinearLayout.LayoutParams(-1, 0, 1); left.addView(qr, qrParams);
        qrCaption = text(18, MINT); qrCaption.setGravity(Gravity.CENTER); left.addView(qrCaption);
        network = new Spinner(this); network.setContentDescription(getString(R.string.network_address)); left.addView(network);
        ScrollView scroll = new ScrollView(this); scroll.setFillViewport(true); root.addView(scroll, new LinearLayout.LayoutParams(0, -1, 0.57f));
        LinearLayout right = new LinearLayout(this); right.setOrientation(LinearLayout.VERTICAL); scroll.addView(right);
        LinearLayout brand = new LinearLayout(this); brand.setGravity(Gravity.CENTER_VERTICAL);
        ImageView logo = new ImageView(this); logo.setImageResource(R.drawable.brand_mark); brand.addView(logo, new LinearLayout.LayoutParams(dp(44), dp(44)));
        TextView title = text(30, INK); title.setText("Sofatap"); title.setPadding(dp(12), 0, 0, 0); brand.addView(title); right.addView(brand);
        TextView subtitle = text(18, MINT); subtitle.setText(R.string.tagline); padded(right, subtitle, 10);
        status = text(22, INK); padded(right, status, 22);
        help = text(16, Color.rgb(181, 206, 198)); padded(right, help, 8);
        permission = button(R.string.enable_accessibility, () -> {
            AlertDialog disclosure = new AlertDialog.Builder(this).setTitle(R.string.permission_needed)
                .setMessage(R.string.accessibility_service_description).setNegativeButton(android.R.string.cancel, null)
                .setPositiveButton(R.string.enable_accessibility, (dialog, which) -> {
                    try { startActivity(new Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)); }
                    catch (ActivityNotFoundException missing) { Toast.makeText(this, R.string.open_settings_manually, Toast.LENGTH_LONG).show(); }
                }).create();
            disclosure.show(); disclosure.getButton(AlertDialog.BUTTON_POSITIVE).setId(R.id.accessibility_setup);
        });
        permission.setId(R.id.accessibility_setup); padded(right, permission, 18);
        start = button(R.string.start, () -> {
            if (ReceiverService.instance != null) { ReceiverStartup.stop(this); }
            else {
                if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED)
                    requestPermissions(new String[]{Manifest.permission.POST_NOTIFICATIONS}, 7);
                ReceiverStartup.start(this);
            }
            refresh();
        }); padded(right, start, 6);
        pair = button(R.string.new_pairing, () -> {
            AlertDialog dialog = new AlertDialog.Builder(this).setTitle(R.string.new_pairing).setMessage(R.string.replace_pairing)
                .setNegativeButton(android.R.string.cancel, null).setPositiveButton(R.string.new_pairing, (d, w) -> {
                    ReceiverService receiver = ReceiverService.instance; if (receiver != null) receiver.newPairing(); refresh();
                }).create();
            dialog.show(); dialog.getButton(AlertDialog.BUTTON_POSITIVE).setId(R.id.pairing_approve);
        }); pair.setId(R.id.pairing_approve); padded(right, pair, 6);
        autoStart = new Switch(this); autoStart.setId(R.id.auto_start);
        autoStart.setText(R.string.auto_start); autoStart.setTextSize(16); autoStart.setTextColor(INK);
        autoStart.setPadding(dp(12), dp(12), dp(12), dp(12)); autoStart.setChecked(startup.enabled());
        autoStart.setOnCheckedChangeListener((button, checked) -> {
            startup.setEnabled(checked);
            if (checked && ReceiverService.instance == null) ReceiverStartup.start(this);
            refresh();
        }); padded(right, autoStart, 12);
        TextView startupHelp = text(14, Color.rgb(164, 189, 180)); startupHelp.setText(R.string.auto_start_help);
        padded(right, startupHelp, 2);
        nativeControls = text(16, MINT); padded(right, nativeControls, 14);
        enableIme = button(R.string.ime_enable, () -> {
            new AlertDialog.Builder(this).setTitle(R.string.ime_enable).setMessage(R.string.ime_disclosure)
                .setNegativeButton(android.R.string.cancel, null).setPositiveButton(R.string.ime_enable, (dialog, which) -> {
                    try { startActivity(new Intent(Settings.ACTION_INPUT_METHOD_SETTINGS)); }
                    catch (ActivityNotFoundException missing) { Toast.makeText(this, R.string.open_settings_manually, Toast.LENGTH_LONG).show(); }
                }).show();
        }); padded(right, enableIme, 6);
        selectIme = button(R.string.ime_select, () -> getSystemService(android.view.inputmethod.InputMethodManager.class).showInputMethodPicker());
        padded(right, selectIme, 6);
        capabilities = text(14, Color.rgb(164, 189, 180)); padded(right, capabilities, 16);
        updates = ReceiverUpdates.get(this);
        updateStatus = text(16, MINT); padded(right, updateStatus, 18);
        autoUpdate = new Switch(this); autoUpdate.setId(R.id.auto_update);
        autoUpdate.setText(R.string.update_automatic); autoUpdate.setTextColor(INK); autoUpdate.setTextSize(16);
        autoUpdate.setPadding(dp(12), dp(8), dp(12), dp(8)); autoUpdate.setChecked(updates.automatic());
        autoUpdate.setVisibility(updates.supported() ? View.VISIBLE : View.GONE);
        autoUpdate.setOnCheckedChangeListener((button, checked) -> updates.setAutomatic(checked)); padded(right, autoUpdate, 6);
        checkUpdate = button(R.string.update_check, () -> {
            if (updates.supported()) updates.check(true);
            else {
                try { startActivity(new Intent(Intent.ACTION_VIEW, android.net.Uri.parse("market://details?id=" + getPackageName())).setPackage("com.android.vending")); }
                catch (ActivityNotFoundException missing) { Toast.makeText(this, R.string.update_store, Toast.LENGTH_LONG).show(); }
            }
            refresh();
        }); checkUpdate.setId(R.id.update_check); padded(right, checkUpdate, 6);
        installUpdate = button(R.string.update_install, () -> { updates.install(this); refresh(); }); installUpdate.setId(R.id.update_install); padded(right, installUpdate, 6);
        cancelUpdate = button(android.R.string.cancel, () -> {
            if (updates.hasInstaller()) updates.cancelInstallation(); else updates.cancelTransfer(); refresh();
        }); cancelUpdate.setId(R.id.update_cancel); padded(right, cancelUpdate, 6);
        TextView updateHelp = text(14, Color.rgb(164, 189, 180)); updateHelp.setText(R.string.update_help); padded(right, updateHelp, 4);
        setContentView(root); renderQR(null); start.requestFocus();
        if (startup.runRequested() && ReceiverService.instance == null) ReceiverStartup.start(this);
    }
    private void refresh() {
        refreshUpdates();
        ReceiverService receiver = ReceiverService.instance;
        ReceiverIdentity identity = receiver == null ? null : receiver.identity;
        ReceiverServer server = receiver == null ? null : receiver.server;
        JSONObject probe = InputBridge.snapshot(this);
        boolean enabled = probe.optBoolean("inputAvailable");
        String nav = receiver == null ? "unavailable" : receiver.navigationStatus();
        boolean nativeReady = nav.equals("ready");
        boolean needsPermission = "accessibility_required".equals(probe.optString("inputStatus"));
        permission.setVisibility(needsPermission ? View.VISIBLE : View.GONE);
        start.setText(receiver == null ? R.string.start : R.string.stop);
        pair.setEnabled(receiver != null && receiver.authority != null);
        pair.setAlpha(pair.isEnabled() ? 1f : 0.4f);
        List<String> currentAddresses = identity == null ? Collections.emptyList() : identity.addresses;
        if (!addresses.equals(currentAddresses)) {
            addresses = new ArrayList<>(currentAddresses);
            ArrayAdapter<String> adapter = new ArrayAdapter<>(this, android.R.layout.simple_spinner_dropdown_item, addresses);
            network.setAdapter(adapter);
        }
        network.setVisibility(addresses.size() > 1 && receiver != null ? View.VISIBLE : View.GONE);
        String address = network.getSelectedItem() instanceof String ? (String)network.getSelectedItem() : addresses.isEmpty() ? "" : addresses.get(0);
        String uri = receiver == null ? null : receiver.pairingUri(address);
        if (!Objects.equals(uri, renderedURI)) { renderedURI = uri; renderQR(uri); }
        boolean connected = server != null && server.connected();
        if (receiver == null) {
            status.setText(startup.blocked() ? R.string.cannot_start : R.string.stopped);
            help.setText(startup.blocked() ? R.string.auto_start_blocked : R.string.start_help); qrCaption.setText(R.string.qr_waiting);
        } else if (receiver.error != null) {
            status.setText(R.string.cannot_start);
            help.setText("no_private_network".equals(receiver.error) ? R.string.connect_network : R.string.restart_help);
        } else if (server == null) {
            status.setText(R.string.starting); help.setText(R.string.start_help);
        } else {
            status.setText(nativeReady ? (connected ? R.string.connected : R.string.ready) : !enabled && !needsPermission ? R.string.input_paused : connected ? enabled ? R.string.connected : R.string.connected_permission : enabled ? R.string.ready : R.string.permission_needed);
            help.setText(nativeReady ? R.string.native_remote_ready : enabled ? R.string.control_help : needsPermission ? R.string.permission_help : R.string.input_paused_help);
            qrCaption.setText(uri != null ? R.string.scan_qr : connected ? R.string.phone_connected : R.string.new_qr_help);
        }
        boolean imeEnabled = SofatapInputMethodService.isEnabled(this), imeSelected = SofatapInputMethodService.isSelected(this);
        enableIme.setVisibility(imeEnabled ? View.GONE : View.VISIBLE);
        selectIme.setVisibility(imeEnabled && !imeSelected ? View.VISIBLE : View.GONE);
        nativeControls.setText(getString(nav.equals("ready") ? R.string.native_remote_ready : nav.equals("pairing") ? R.string.native_remote_pairing : R.string.native_remote_setup)
            + "\n" + getString(imeSelected ? R.string.ime_selected_help : R.string.ime_setup_help));
        capabilities.setText(R.string.probe_limitations);
    }
    private void refreshUpdates() {
        String state = updates.status();
        int message = switch (state) {
            case "checking" -> R.string.update_checking;
            case "downloading" -> R.string.update_downloading;
            case "ready" -> R.string.update_ready;
            case "latest" -> R.string.update_latest;
            case "recent" -> R.string.update_recent;
            case "rate_limited" -> R.string.update_rate_limited;
            case "permission", "permission_missing" -> R.string.update_permission;
            case "preparing" -> R.string.update_preparing;
            case "confirm" -> R.string.update_confirmation;
            case "pending" -> R.string.update_pending;
            case "installed" -> R.string.update_installed;
            case "cancelled" -> R.string.update_cancelled;
            case "failed", "install_failed" -> R.string.update_failed;
            case "store" -> R.string.update_store;
            default -> R.string.update_current;
        };
        updateStatus.setText(getString(message, updates.version()));
        checkUpdate.setEnabled(!updates.busy() && !updates.hasInstaller());
        installUpdate.setVisibility(updates.canInstall() ? View.VISIBLE : View.GONE);
        installUpdate.setText(state.equals("confirm") ? R.string.update_continue : R.string.update_install);
        cancelUpdate.setVisibility(updates.busy() || updates.hasInstaller() ? View.VISIBLE : View.GONE);
    }
    private void renderQR(String uri) {
        if (uri == null) {
            qr.setImageResource(R.drawable.brand_mark); qr.setPadding(dp(46), dp(46), dp(46), dp(46));
            getWindow().clearFlags(WindowManager.LayoutParams.FLAG_SECURE); return;
        }
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_SECURE);
        try {
            Map<EncodeHintType, Object> hints = new EnumMap<>(EncodeHintType.class); hints.put(EncodeHintType.MARGIN, 4);
            BitMatrix matrix = new MultiFormatWriter().encode(uri, BarcodeFormat.QR_CODE, 640, 640, hints);
            int[] pixels = new int[640 * 640];
            for (int y = 0; y < 640; y++) for (int x = 0; x < 640; x++) pixels[y * 640 + x] = matrix.get(x, y) ? Color.BLACK : Color.WHITE;
            qr.setPadding(0, 0, 0, 0); qr.setImageBitmap(Bitmap.createBitmap(pixels, 640, 640, Bitmap.Config.ARGB_8888));
        } catch (Exception error) { qr.setImageDrawable(null); qrCaption.setText(R.string.qr_failed); }
    }
    private TextView text(int size, int color) { TextView view = new TextView(this); view.setTextSize(size); view.setTextColor(color); return view; }
    private Button button(int label, Runnable action) {
        Button b = new Button(this); b.setText(label); b.setAllCaps(false); b.setTextSize(16); b.setTextColor(BACKGROUND);
        b.setPadding(dp(16), dp(8), dp(16), dp(8));
        b.setOnFocusChangeListener((v, focused) -> {
            GradientDrawable shape = new GradientDrawable(); shape.setColor(focused ? Color.WHITE : MINT); shape.setCornerRadius(dp(12));
            shape.setStroke(dp(focused ? 3 : 0), Color.rgb(61, 172, 131)); b.setBackground(shape);
        });
        GradientDrawable shape = new GradientDrawable(); shape.setColor(MINT); shape.setCornerRadius(dp(12)); b.setBackground(shape);
        b.setOnClickListener(v -> action.run()); return b;
    }
    private void padded(LinearLayout parent, View view, int top) {
        LinearLayout.LayoutParams params = new LinearLayout.LayoutParams(-1, -2); params.topMargin = dp(top); parent.addView(view, params);
    }
    private int dp(int value) { return Math.round(value * getResources().getDisplayMetrics().density); }
    @Override protected void onResume() { super.onResume(); active = true; main.post(tick); }
    @Override protected void onPause() { active = false; main.removeCallbacks(tick); super.onPause(); }
}
