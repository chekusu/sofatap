package com.chekusu.sofatap.tv;

import android.Manifest;
import android.app.*;
import android.content.*;
import android.content.pm.PackageManager;
import android.graphics.*;
import android.graphics.drawable.GradientDrawable;
import android.os.*;
import android.provider.Settings;
import android.util.TypedValue;
import android.view.*;
import android.widget.*;
import com.chekusu.sofatap.tv.input.InputBridge;
import com.chekusu.sofatap.tv.ui.NebulaView;
import com.chekusu.sofatap.tv.ui.OnboardingFlow;
import com.chekusu.sofatap.tv.ui.OnboardingFlow.Stage;
import com.google.zxing.*;
import com.google.zxing.common.BitMatrix;
import org.json.JSONObject;
import java.util.*;

/**
 * TV-native receiver screen, design A "Nebula": a particle cloud with the pairing code at its
 * centre, an onboarding that asks for TV control first, and a guide driven by real phone input.
 * Receiver settings live on a separate panel (Menu key or the Settings button). No WebView.
 */
public final class MainActivity extends Activity {
    private static final int INK = Color.rgb(240, 245, 243), MUTED = Color.argb(165, 240, 245, 243), MINT = Color.rgb(152, 233, 196),
        PANEL = Color.rgb(17, 25, 27), WARN = Color.rgb(255, 184, 107), DARK = Color.rgb(12, 21, 19);
    private static final float QR_X = 800, QR_Y = 330, QR_SIZE = 240;
    private final Handler main = new Handler(Looper.getMainLooper());
    // Stage (design space 1600 × 900, scaled to the screen).
    private FrameLayout stage;
    private NebulaView nebula;
    private FrameLayout qrIsland;
    private ImageView qr;
    private TextView meta, kicker, title, body, pill;
    private LinearLayout actions;
    private final List<TextView> deviceLabels = new ArrayList<>();
    private float scale = 1;
    // Settings panel.
    private ScrollView settingsPanel;
    private TextView status, help, capabilities, nativeControls, updateStatus;
    private Button start, pair, enableIme, selectIme, checkUpdate, installUpdate, cancelUpdate;
    private Switch autoStart, autoUpdate;
    private Spinner network;
    private ReceiverStartup startup;
    private ReceiverUpdates updates;
    private String renderedURI;
    private List<String> addresses = new ArrayList<>();
    private OnboardingFlow flow;
    private final OnboardingFlow.Inputs inputs = new OnboardingFlow.Inputs();
    private boolean active, connected, needsPermission;
    private String address = "";
    private final Runnable tick = new Runnable() { @Override public void run() { if (active) { refresh(); main.postDelayed(this, 350); } } };

    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        startup = new ReceiverStartup(this); startup.initializeFromVisibleLaunch();
        updates = ReceiverUpdates.get(this);
        flow = new OnboardingFlow(prefs().getBoolean("onboarded", false));
        // QR bearer credentials must not leak through screenshots/cast previews.
        getWindow().setFlags(WindowManager.LayoutParams.FLAG_SECURE, WindowManager.LayoutParams.FLAG_SECURE);
        FrameLayout root = new FrameLayout(this);
        GradientDrawable sky = new GradientDrawable(GradientDrawable.Orientation.TOP_BOTTOM, new int[]{Color.rgb(13, 27, 27), Color.rgb(7, 12, 14), Color.rgb(3, 5, 6)});
        sky.setGradientType(GradientDrawable.RADIAL_GRADIENT); sky.setGradientCenter(0.5f, 0.38f); sky.setGradientRadius(dp(700));
        root.setBackground(sky);
        buildStage(root);
        buildSettings(root);
        root.addOnLayoutChangeListener((v, l, t, r, b, ol, ot, or, ob) -> fitStage(r - l, b - t));
        setContentView(root);
        renderQR(null);
        if (startup.runRequested() && ReceiverService.instance == null) ReceiverStartup.start(this);
        refresh();
    }

    // ---------- stage ----------
    private void buildStage(FrameLayout root) {
        stage = new FrameLayout(this); stage.setClipChildren(false);
        root.addView(stage, new FrameLayout.LayoutParams((int) NebulaView.W, (int) NebulaView.H));
        stage.setPivotX(0); stage.setPivotY(0);
        nebula = new NebulaView(this); nebula.setCloudCenter(QR_X, QR_Y);
        stage.addView(nebula, new FrameLayout.LayoutParams((int) NebulaView.W, (int) NebulaView.H));
        qrIsland = new FrameLayout(this);
        GradientDrawable white = new GradientDrawable(); white.setColor(Color.WHITE); white.setCornerRadius(26); qrIsland.setBackground(white);
        qr = new ImageView(this); qr.setScaleType(ImageView.ScaleType.FIT_CENTER); qr.setContentDescription(getString(R.string.qr_description));
        int pad = Math.round(QR_SIZE * 0.08f); qrIsland.setPadding(pad, pad, pad, pad);
        qrIsland.addView(qr, new FrameLayout.LayoutParams(-1, -1));
        place(qrIsland, QR_X - QR_SIZE / 2, QR_Y - QR_SIZE / 2, QR_SIZE, QR_SIZE);
        meta = text(20, MUTED); meta.setGravity(Gravity.CENTER); place(meta, 400, QR_Y + QR_SIZE / 2 + 16, 800, -2);
        LinearLayout block = new LinearLayout(this); block.setOrientation(LinearLayout.VERTICAL); block.setGravity(Gravity.CENTER_HORIZONTAL);
        kicker = text(21, MINT); kicker.setLetterSpacing(0.2f); kicker.setGravity(Gravity.CENTER); kicker.setAllCaps(true); block.addView(kicker);
        title = text(56, INK); title.setGravity(Gravity.CENTER); title.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
        LinearLayout.LayoutParams tp = new LinearLayout.LayoutParams(-2, -2); tp.topMargin = 12; block.addView(title, tp);
        body = text(27, MUTED); body.setGravity(Gravity.CENTER); body.setLineSpacing(0, 1.3f);
        LinearLayout.LayoutParams bp = new LinearLayout.LayoutParams(-2, -2); bp.topMargin = 14; block.addView(body, bp);
        actions = new LinearLayout(this); actions.setGravity(Gravity.CENTER);
        LinearLayout.LayoutParams ap = new LinearLayout.LayoutParams(-2, -2); ap.topMargin = 30; block.addView(actions, ap);
        place(block, 250, 0, 1100, -2); blockView = block;
        pill = text(21, INK); pill.setPadding(22, 10, 22, 10); pill.setCompoundDrawablePadding(12);
        GradientDrawable pillBg = new GradientDrawable(); pillBg.setColor(Color.argb(18, 255, 255, 255)); pillBg.setCornerRadius(999); pill.setBackground(pillBg);
        FrameLayout.LayoutParams pp = new FrameLayout.LayoutParams(-2, -2, Gravity.TOP | Gravity.END); pp.topMargin = 50; pp.rightMargin = 60; stage.addView(pill, pp);
        String[] labels = {getString(R.string.nebula_label_mac), getString(R.string.nebula_label_tv), getString(R.string.nebula_label_pc)};
        float[][] at = {{360, 400}, {800, 390}, {1240, 390}};
        for (int i = 0; i < 3; i++) { TextView l = text(21, MUTED); l.setText(labels[i]); l.setGravity(Gravity.CENTER); place(l, at[i][0] - 150, at[i][1], 300, -2); deviceLabels.add(l); }
    }
    private LinearLayout blockView;

    private void place(View v, float x, float y, float w, float h) {
        FrameLayout.LayoutParams p = new FrameLayout.LayoutParams(Math.round(w), Math.round(h));
        p.leftMargin = Math.round(x); p.topMargin = Math.round(y); stage.addView(v, p);
    }
    private void moveBlock(float y) { FrameLayout.LayoutParams p = (FrameLayout.LayoutParams) blockView.getLayoutParams(); p.topMargin = Math.round(y); blockView.setLayoutParams(p); }

    private void fitStage(int w, int h) {
        if (w == 0 || h == 0) return;
        scale = Math.min(w / NebulaView.W, h / NebulaView.H);
        stage.setScaleX(scale); stage.setScaleY(scale);
        stage.setTranslationX((w - NebulaView.W * scale) / 2); stage.setTranslationY((h - NebulaView.H * scale) / 2);
    }

    /** Shows one onboarding stage: particle scene, words and the remote-focusable actions. */
    private void render() {
        Stage s = flow.stage(); if (s == null) return;
        boolean qrShown = s == Stage.READY && renderedURI != null;
        qrIsland.setVisibility(qrShown ? View.VISIBLE : View.GONE); meta.setVisibility(qrShown ? View.VISIBLE : View.GONE);
        for (TextView l : deviceLabels) l.setVisibility(s == Stage.SCREENS ? View.VISIBLE : View.GONE);
        actions.removeAllViews(); kicker.setText(""); body.setText(""); kicker.setTextColor(MINT);
        float y = 640;
        switch (s) {
            case STOPPED:
                nebula.setScene(NebulaView.Scene.IDLE); nebula.setDim(0.5f); y = 560;
                title.setText(startup.blocked() ? R.string.cannot_start : R.string.stopped);
                body.setText(startup.blocked() ? R.string.auto_start_blocked : R.string.start_help);
                action(R.string.start, true, this::toggleReceiver).requestFocus(); action(R.string.nebula_settings, false, () -> showSettings(true));
                pill(R.string.stopped, false); break;
            case PREPARING:
                nebula.setScene(NebulaView.Scene.IDLE); nebula.setDim(0.7f); y = 560;
                title.setText(R.string.starting); body.setText(R.string.start_help);
                action(R.string.nebula_settings, false, () -> showSettings(true)).requestFocus(); pill(R.string.starting, false); break;
            case ERROR: {
                ReceiverService receiver = ReceiverService.instance;
                nebula.setScene(NebulaView.Scene.IDLE); nebula.setDim(0.5f); y = 560;
                title.setText(R.string.cannot_start);
                body.setText(receiver != null && "no_private_network".equals(receiver.error) ? R.string.connect_network : R.string.restart_help);
                action(R.string.stop, true, this::toggleReceiver).requestFocus(); action(R.string.nebula_settings, false, () -> showSettings(true));
                pill(R.string.cannot_start, true); break;
            }
            case PERMISSION:
                nebula.setScene(NebulaView.Scene.PERMISSION); nebula.setDim(1); y = 560;
                kicker.setText(flow.onboarded() || connected ? R.string.nebula_permission_kicker_late : R.string.nebula_permission_kicker);
                title.setText(R.string.nebula_permission_title); body.setText(R.string.nebula_permission_body);
                Button allow = action(R.string.enable_accessibility, true, this::askAccessibility); allow.setId(R.id.accessibility_setup); allow.requestFocus();
                action(R.string.nebula_later, false, () -> { flow.advance(now()); render(); });
                pill(R.string.permission_needed, true); break;
            case READY:
                nebula.setScene(NebulaView.Scene.CLOUD); nebula.setDim(1);
                kicker.setText(R.string.nebula_brand); title.setText(R.string.nebula_ready_title); body.setText(R.string.nebula_ready_body);
                meta.setText(getString(R.string.nebula_meta, getString(R.string.nebula_label_tv), address));
                action(R.string.nebula_settings, false, () -> showSettings(true)).requestFocus();
                pill(R.string.ready, false); break;
            case LINKING:
                nebula.burstFrom(QR_X, QR_Y, QR_SIZE * 0.84f); nebula.setScene(NebulaView.Scene.COLLAPSE); nebula.setDim(1);
                kicker.setText(R.string.nebula_linking_kicker); title.setText(R.string.nebula_linking_title); body.setText(R.string.nebula_linking_body);
                pill(R.string.nebula_linking_kicker, false); break;
            case CONNECTED:
                nebula.pulse(800, 330); nebula.setScene(NebulaView.Scene.PHONE); nebula.setDim(1);
                kicker.setText(R.string.nebula_connected_kicker); title.setText(R.string.nebula_connected_title); body.setText(R.string.nebula_connected_body);
                pill(R.string.connected, false); break;
            case GUIDE_MOVE:
            case GUIDE_TAP: {
                boolean move = s == Stage.GUIDE_MOVE;
                nebula.setScene(NebulaView.Scene.STARS); nebula.setDim(1); y = 620;
                kicker.setText(move ? R.string.nebula_move_kicker : R.string.nebula_tap_kicker);
                title.setText(move ? R.string.nebula_move_title : R.string.nebula_tap_title);
                body.setText(move ? R.string.nebula_move_body : R.string.nebula_tap_body);
                action(R.string.nebula_skip, false, () -> { flow.skipGuide(now()); saveOnboarded(); render(); }).requestFocus();
                pill(R.string.connected, false); break;
            }
            case SCREENS:
                nebula.setScene(NebulaView.Scene.SCREENS); nebula.setDim(1);
                kicker.setText(R.string.nebula_screens_kicker); title.setText(R.string.nebula_screens_title); body.setText(R.string.nebula_screens_body);
                action(R.string.nebula_done, true, () -> { flow.advance(now()); saveOnboarded(); render(); }).requestFocus();
                pill(R.string.connected, false); break;
            case IDLE:
            default:
                nebula.setScene(NebulaView.Scene.IDLE); nebula.setDim(1); y = 590;
                kicker.setText(R.string.app_name); title.setText(connected ? R.string.connected : R.string.nebula_idle_title);
                body.setText(connected ? R.string.nebula_idle_connected_body : R.string.nebula_idle_body);
                View first = null;
                if (needsPermission) first = action(R.string.enable_accessibility, true, this::askAccessibility);
                View p = action(R.string.new_pairing, false, this::confirmNewPairing);
                action(R.string.nebula_settings, false, () -> showSettings(true));
                (first != null ? first : p).requestFocus();
                pill(connected ? R.string.connected : R.string.phone_connected, needsPermission);
        }
        moveBlock(y);
    }

    private void pill(int text, boolean warn) {
        pill.setText(text);
        GradientDrawable dot = new GradientDrawable(); dot.setShape(GradientDrawable.OVAL); dot.setColor(warn ? WARN : MINT); dot.setSize(12, 12);
        dot.setBounds(0, 0, 12, 12); pill.setCompoundDrawables(dot, null, null, null);
    }

    private Button action(int label, boolean primary, Runnable run) {
        Button b = new Button(this); b.setText(label); b.setAllCaps(false); b.setTextSize(TypedValue.COMPLEX_UNIT_PX, 27);
        b.setPadding(38, 16, 38, 16); b.setMinHeight(0); b.setMinimumHeight(0); b.setStateListAnimator(null);
        Runnable paint = () -> {
            GradientDrawable shape = new GradientDrawable(); shape.setCornerRadius(999);
            boolean f = b.isFocused();
            if (primary) { shape.setColor(f ? Color.WHITE : MINT); shape.setStroke(f ? 6 : 0, MINT); b.setTextColor(DARK); }
            else { shape.setColor(f ? Color.argb(46, 255, 255, 255) : Color.TRANSPARENT); shape.setStroke(f ? 4 : 2, f ? INK : Color.argb(60, 255, 255, 255)); b.setTextColor(INK); }
            b.setBackground(shape); b.setScaleX(f ? 1.06f : 1f); b.setScaleY(f ? 1.06f : 1f);
        };
        paint.run(); b.setOnFocusChangeListener((v, f) -> paint.run());
        b.setOnClickListener(v -> run.run());
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(-2, -2); lp.leftMargin = lp.rightMargin = 10;
        actions.addView(b, lp); return b;
    }

    // ---------- settings panel (all receiver controls) ----------
    private void buildSettings(FrameLayout root) {
        settingsPanel = new ScrollView(this); settingsPanel.setBackgroundColor(PANEL); settingsPanel.setVisibility(View.GONE);
        LinearLayout list = new LinearLayout(this); list.setOrientation(LinearLayout.VERTICAL); list.setPadding(dp(32), dp(24), dp(32), dp(24));
        settingsPanel.addView(list);
        FrameLayout.LayoutParams sp = new FrameLayout.LayoutParams(dp(460), -1, Gravity.END); root.addView(settingsPanel, sp);
        Button back = button(R.string.nebula_settings_back, () -> showSettings(false)); padded(list, back, 0);
        TextView heading = text(0, INK); heading.setTextSize(26); heading.setText(R.string.nebula_settings); padded(list, heading, 18);
        status = text(0, INK); status.setTextSize(18); padded(list, status, 14);
        help = text(0, MUTED); help.setTextSize(15); padded(list, help, 6);
        start = button(R.string.start, this::toggleReceiver); padded(list, start, 14);
        pair = button(R.string.new_pairing, this::confirmNewPairing); pair.setId(R.id.pairing_approve); padded(list, pair, 6);
        network = new Spinner(this); network.setContentDescription(getString(R.string.network_address)); padded(list, network, 6);
        autoStart = new Switch(this); autoStart.setId(R.id.auto_start);
        autoStart.setText(R.string.auto_start); autoStart.setTextSize(16); autoStart.setTextColor(INK);
        autoStart.setPadding(dp(12), dp(12), dp(12), dp(12)); autoStart.setChecked(startup.enabled());
        autoStart.setOnCheckedChangeListener((button, checked) -> {
            startup.setEnabled(checked);
            if (checked && ReceiverService.instance == null) ReceiverStartup.start(this);
            refresh();
        }); padded(list, autoStart, 12);
        TextView startupHelp = text(0, MUTED); startupHelp.setTextSize(14); startupHelp.setText(R.string.auto_start_help); padded(list, startupHelp, 2);
        nativeControls = text(0, MINT); nativeControls.setTextSize(15); padded(list, nativeControls, 14);
        enableIme = button(R.string.ime_enable, () -> new AlertDialog.Builder(this).setTitle(R.string.ime_enable).setMessage(R.string.ime_disclosure)
            .setNegativeButton(android.R.string.cancel, null).setPositiveButton(R.string.ime_enable, (dialog, which) ->
                openSettings(Settings.ACTION_INPUT_METHOD_SETTINGS, R.string.ime_settings_missing, SettingsFallback::inputMethodCommands)).show());
        padded(list, enableIme, 6);
        selectIme = button(R.string.ime_select, () -> getSystemService(android.view.inputmethod.InputMethodManager.class).showInputMethodPicker());
        padded(list, selectIme, 6);
        capabilities = text(0, MUTED); capabilities.setTextSize(14); padded(list, capabilities, 16);
        updateStatus = text(0, MINT); updateStatus.setTextSize(15); padded(list, updateStatus, 18);
        autoUpdate = new Switch(this); autoUpdate.setId(R.id.auto_update);
        autoUpdate.setText(R.string.update_automatic); autoUpdate.setTextColor(INK); autoUpdate.setTextSize(16);
        autoUpdate.setPadding(dp(12), dp(8), dp(12), dp(8)); autoUpdate.setChecked(updates.automatic());
        autoUpdate.setVisibility(updates.supported() ? View.VISIBLE : View.GONE);
        autoUpdate.setOnCheckedChangeListener((button, checked) -> updates.setAutomatic(checked)); padded(list, autoUpdate, 6);
        checkUpdate = button(R.string.update_check, () -> {
            if (updates.supported()) updates.check(true);
            else {
                try { startActivity(new Intent(Intent.ACTION_VIEW, android.net.Uri.parse("market://details?id=" + getPackageName())).setPackage("com.android.vending")); }
                catch (ActivityNotFoundException missing) { Toast.makeText(this, R.string.update_store, Toast.LENGTH_LONG).show(); }
            }
            refresh();
        }); checkUpdate.setId(R.id.update_check); padded(list, checkUpdate, 6);
        installUpdate = button(R.string.update_install, () -> { updates.install(this); refresh(); }); installUpdate.setId(R.id.update_install); padded(list, installUpdate, 6);
        cancelUpdate = button(android.R.string.cancel, () -> {
            if (updates.hasInstaller()) updates.cancelInstallation(); else updates.cancelTransfer(); refresh();
        }); cancelUpdate.setId(R.id.update_cancel); padded(list, cancelUpdate, 6);
        TextView updateHelp = text(0, MUTED); updateHelp.setTextSize(14); updateHelp.setText(R.string.update_help); padded(list, updateHelp, 4);
    }

    private final android.window.OnBackInvokedCallback closeSettings = Build.VERSION.SDK_INT >= 33 ? () -> showSettings(false) : null;

    private void showSettings(boolean show) {
        settingsPanel.setVisibility(show ? View.VISIBLE : View.GONE);
        if (Build.VERSION.SDK_INT >= 33) {
            if (show) getOnBackInvokedDispatcher().registerOnBackInvokedCallback(android.window.OnBackInvokedDispatcher.PRIORITY_DEFAULT, closeSettings);
            else getOnBackInvokedDispatcher().unregisterOnBackInvokedCallback(closeSettings);
        }
        stage.setDescendantFocusability(show ? ViewGroup.FOCUS_BLOCK_DESCENDANTS : ViewGroup.FOCUS_AFTER_DESCENDANTS);
        if (show) { settingsPanel.scrollTo(0, 0); ((ViewGroup) settingsPanel.getChildAt(0)).getChildAt(0).requestFocus(); }
        else render();
    }

    @Override public boolean onKeyDown(int keyCode, KeyEvent event) {
        if (keyCode == KeyEvent.KEYCODE_MENU) { showSettings(settingsPanel.getVisibility() != View.VISIBLE); return true; }
        if (keyCode == KeyEvent.KEYCODE_BACK && Build.VERSION.SDK_INT < 33 && settingsPanel.getVisibility() == View.VISIBLE) { showSettings(false); return true; }
        return super.onKeyDown(keyCode, event);
    }

    // ---------- actions ----------
    private void toggleReceiver() {
        if (ReceiverService.instance != null) { ReceiverStartup.stop(this); }
        else {
            if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED)
                requestPermissions(new String[]{Manifest.permission.POST_NOTIFICATIONS}, 7);
            ReceiverStartup.start(this);
        }
        refresh();
    }

    private void askAccessibility() {
        AlertDialog disclosure = new AlertDialog.Builder(this).setTitle(R.string.permission_needed)
            .setMessage(R.string.accessibility_service_description).setNegativeButton(android.R.string.cancel, null)
            .setPositiveButton(R.string.enable_accessibility, (dialog, which) ->
                openSettings(Settings.ACTION_ACCESSIBILITY_SETTINGS, R.string.accessibility_settings_missing,
                    () -> SettingsFallback.accessibilityCommands(Settings.Secure.getString(getContentResolver(), "enabled_accessibility_services"))))
            .create();
        disclosure.show(); disclosure.getButton(AlertDialog.BUTTON_POSITIVE).requestFocus();
    }

    private void confirmNewPairing() {
        AlertDialog dialog = new AlertDialog.Builder(this).setTitle(R.string.new_pairing).setMessage(R.string.replace_pairing)
            .setNegativeButton(android.R.string.cancel, null).setPositiveButton(R.string.new_pairing, (d, w) -> {
                ReceiverService receiver = ReceiverService.instance; if (receiver != null) receiver.newPairing(); refresh();
            }).create();
        dialog.show(); dialog.getButton(AlertDialog.BUTTON_POSITIVE).requestFocus();
    }

    /**
     * Opens a system settings page, or explains on screen why it cannot. Vendor ROMs without
     * the page (seen on an XGIMI projector) used to get only a brief toast the owner could not act on.
     */
    private void openSettings(String action, int missingMessage, java.util.function.Supplier<String> adbCommands) {
        // Launch directly: with package visibility, resolveActivity() can miss a page that opens fine.
        try { startActivity(new Intent(action)); return; } catch (ActivityNotFoundException | SecurityException ignored) { }
        TextView text = text(0, INK); text.setTextSize(15); text.setTextIsSelectable(true);
        text.setText(getString(missingMessage) + "\n\n" + adbCommands.get());
        text.setPadding(dp(24), dp(12), dp(24), dp(4));
        ScrollView holder = new ScrollView(this); holder.addView(text);
        AlertDialog dialog = new AlertDialog.Builder(this).setTitle(R.string.settings_missing_title)
            .setView(holder).setPositiveButton(android.R.string.ok, null).create();
        dialog.show(); dialog.getButton(AlertDialog.BUTTON_POSITIVE).requestFocus();
    }

    /** Real phone input drives the guide and makes the particles part around the pointer. */
    private void onPhoneInput(String action, JSONObject result) {
        if ("move".equals(action) && result.has("x") && result.has("y")) {
            int[] at = new int[2]; stage.getLocationOnScreen(at);
            cursorX = ((float) result.optDouble("x") - at[0]) / scale; cursorY = ((float) result.optDouble("y") - at[1]) / scale;
            nebula.setCursor(cursorX, cursorY);
        } else if ("click".equals(action) || "scroll".equals(action)) {
            nebula.pulse(cursorX, cursorY);
        }
        if (flow.onInput(action, now())) render();
    }
    private float cursorX = 800, cursorY = 450;

    // ---------- state ----------
    private void refresh() {
        refreshUpdates();
        ReceiverService receiver = ReceiverService.instance;
        ReceiverIdentity identity = receiver == null ? null : receiver.identity;
        ReceiverServer server = receiver == null ? null : receiver.server;
        JSONObject probe = InputBridge.snapshot(this);
        boolean enabled = probe.optBoolean("inputAvailable");
        String nav = receiver == null ? "unavailable" : receiver.navigationStatus();
        boolean nativeReady = nav.equals("ready");
        needsPermission = "accessibility_required".equals(probe.optString("inputStatus"));
        start.setText(receiver == null ? R.string.start : R.string.stop);
        pair.setEnabled(receiver != null && receiver.authority != null);
        pair.setAlpha(pair.isEnabled() ? 1f : 0.4f);
        List<String> currentAddresses = identity == null ? Collections.emptyList() : identity.addresses;
        if (!addresses.equals(currentAddresses)) {
            addresses = new ArrayList<>(currentAddresses);
            network.setAdapter(new ArrayAdapter<>(this, android.R.layout.simple_spinner_dropdown_item, addresses));
        }
        network.setVisibility(addresses.size() > 1 && receiver != null ? View.VISIBLE : View.GONE);
        address = network.getSelectedItem() instanceof String ? (String) network.getSelectedItem() : addresses.isEmpty() ? "" : addresses.get(0);
        String uri = receiver == null ? null : receiver.pairingUri(address);
        boolean qrChanged = !Objects.equals(uri, renderedURI);
        if (qrChanged) { renderedURI = uri; renderQR(uri); }
        connected = server != null && server.connected();
        if (receiver == null) {
            status.setText(startup.blocked() ? R.string.cannot_start : R.string.stopped);
            help.setText(startup.blocked() ? R.string.auto_start_blocked : R.string.start_help);
        } else if (receiver.error != null) {
            status.setText(R.string.cannot_start);
            help.setText("no_private_network".equals(receiver.error) ? R.string.connect_network : R.string.restart_help);
        } else if (server == null) {
            status.setText(R.string.starting); help.setText(R.string.start_help);
        } else {
            status.setText(nativeReady ? (connected ? R.string.connected : R.string.ready) : !enabled && !needsPermission ? R.string.input_paused : connected ? enabled ? R.string.connected : R.string.connected_permission : enabled ? R.string.ready : R.string.permission_needed);
            help.setText(nativeReady ? R.string.native_remote_ready : enabled ? R.string.control_help : needsPermission ? R.string.permission_help : R.string.input_paused_help);
        }
        boolean imeEnabled = SofatapInputMethodService.isEnabled(this), imeSelected = SofatapInputMethodService.isSelected(this);
        enableIme.setVisibility(imeEnabled ? View.GONE : View.VISIBLE);
        selectIme.setVisibility(imeEnabled && !imeSelected ? View.VISIBLE : View.GONE);
        nativeControls.setText(getString(nav.equals("ready") ? R.string.native_remote_ready : nav.equals("pairing") ? R.string.native_remote_pairing : R.string.native_remote_setup)
            + "\n" + getString(imeSelected ? R.string.ime_selected_help : R.string.ime_setup_help));
        capabilities.setText(R.string.probe_limitations);
        inputs.set(receiver != null, server != null, receiver != null && receiver.error != null, uri != null, connected, needsPermission);
        boolean wasOnboarded = flow.onboarded();
        if (flow.update(inputs, now()) || qrChanged) render();
        if (!wasOnboarded && flow.onboarded()) saveOnboarded();
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
            qr.setImageDrawable(null);
            getWindow().clearFlags(WindowManager.LayoutParams.FLAG_SECURE); return;
        }
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_SECURE);
        try {
            Map<EncodeHintType, Object> hints = new EnumMap<>(EncodeHintType.class); hints.put(EncodeHintType.MARGIN, 2);
            BitMatrix matrix = new MultiFormatWriter().encode(uri, BarcodeFormat.QR_CODE, 640, 640, hints);
            int[] pixels = new int[640 * 640];
            for (int y = 0; y < 640; y++) for (int x = 0; x < 640; x++) pixels[y * 640 + x] = matrix.get(x, y) ? Color.BLACK : Color.WHITE;
            qr.setImageBitmap(Bitmap.createBitmap(pixels, 640, 640, Bitmap.Config.ARGB_8888));
        } catch (Exception error) { qr.setImageDrawable(null); meta.setText(R.string.qr_failed); }
    }

    // ---------- helpers ----------
    private SharedPreferences prefs() { return getSharedPreferences("nebula", MODE_PRIVATE); }
    private void saveOnboarded() { if (flow.onboarded()) prefs().edit().putBoolean("onboarded", true).apply(); }
    private static long now() { return SystemClock.uptimeMillis(); }
    /** Stage text in design pixels (size > 0) or a plain view whose size the caller sets. */
    private TextView text(int designPx, int color) {
        TextView view = new TextView(this); view.setTextColor(color);
        if (designPx > 0) view.setTextSize(TypedValue.COMPLEX_UNIT_PX, designPx);
        return view;
    }
    private Button button(int label, Runnable action) {
        Button b = new Button(this); b.setText(label); b.setAllCaps(false); b.setTextSize(16); b.setTextColor(DARK);
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
    @Override protected void onResume() {
        super.onResume(); active = true; main.post(tick);
        InputBridge.setObserver((action, result) -> main.post(() -> onPhoneInput(action, result)));
    }
    @Override protected void onPause() { active = false; main.removeCallbacks(tick); InputBridge.setObserver(null); super.onPause(); }
}
