package com.chekusu.sofatap.controller;

import android.content.Context;
import android.security.keystore.KeyGenParameterSpec;
import android.security.keystore.KeyProperties;
import org.json.JSONArray;
import org.json.JSONObject;
import java.io.File;
import java.io.FileOutputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.StandardCopyOption;
import java.security.KeyStore;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.List;
import javax.crypto.Cipher;
import javax.crypto.KeyGenerator;
import javax.crypto.SecretKey;
import javax.crypto.spec.GCMParameterSpec;

/** Pairing credentials never leave the app's encrypted, backup-excluded private directory. */
public final class DeviceStore {
    private static final String KEY_ALIAS = "com.chekusu.sofatap.controller.devices.v1";
    private static final byte[] AAD = "Sofatap controller device store v1".getBytes(StandardCharsets.UTF_8);
    private static final int MAX_STORE_BYTES = 1024 * 1024;
    private static final int MAX_DEVICES = 100;
    private final File file;
    private final SecretKey key;
    private List<Device> devices;
    private String selected;

    public static final class Device {
        public final String id;
        public final String name;
        public final Pairing pairing;
        private Device(String id, String name, Pairing pairing) { this.id = id; this.name = name; this.pairing = pairing; }
    }

    public DeviceStore(Context context) {
        this(new File(context.getNoBackupFilesDir(), "paired-devices.enc"), null);
    }

    /** Package-scoped key injection permits storage regression tests without an Android keystore. */
    DeviceStore(File file, SecretKey testKey) {
        this.file = file;
        try {
            key = testKey == null ? loadKey(!file.exists()) : testKey;
            read();
        } catch (Exception unavailable) {
            // Do not replace an unreadable store or key: callers must surface a recoverable error.
            throw new IllegalStateException("Saved devices could not be opened");
        }
    }

    public synchronized List<Device> list() { return Collections.unmodifiableList(new ArrayList<>(devices)); }
    public synchronized String selectedId() { return selected; }
    public synchronized Device selected() { return find(selected); }

    public synchronized Device save(Pairing pairing) {
        if (pairing == null) throw new IllegalArgumentException("Missing device");
        String id = pairing.identity();
        Device previous = find(id);
        Device device = new Device(id, previous == null ? defaultName(pairing) : previous.name, pairing);
        List<Device> next = new ArrayList<>(devices);
        if (previous != null) next.set(next.indexOf(previous), device);
        else {
            if (next.size() >= MAX_DEVICES) throw new IllegalStateException("Too many saved devices");
            next.add(device);
        }
        persist(next, id);
        return device;
    }

    public synchronized void select(String id) {
        if (id != null && find(id) == null) throw new IllegalArgumentException("Unknown device");
        persist(devices, id);
    }

    public synchronized void rename(String id, String name) {
        Device previous = find(id);
        if (previous == null) throw new IllegalArgumentException("Unknown device");
        String clean = validName(name);
        List<Device> next = new ArrayList<>(devices);
        next.set(next.indexOf(previous), new Device(id, clean, previous.pairing));
        persist(next, selected);
    }

    public synchronized void remove(String id) {
        Device previous = find(id);
        if (previous == null) return;
        List<Device> next = new ArrayList<>(devices);
        next.remove(previous);
        persist(next, id.equals(selected) ? null : selected);
    }

    private Device find(String id) {
        if (id != null) for (Device device : devices) if (device.id.equals(id)) return device;
        return null;
    }

    private static String defaultName(Pairing pairing) {
        return pairing.name == null || pairing.name.trim().isEmpty()
            ? (pairing.isTv() ? "Android TV" : pairing.host) : validName(pairing.name);
    }

    private static String validName(String name) {
        if (name == null) throw new IllegalArgumentException("Invalid device name");
        String clean = name.trim();
        if (clean.isEmpty() || clean.codePointCount(0, clean.length()) > 80
            || clean.getBytes(StandardCharsets.UTF_8).length > 256
            || clean.codePoints().anyMatch(c -> Character.isISOControl(c) || Character.getType(c) == Character.FORMAT)) {
            throw new IllegalArgumentException("Invalid device name");
        }
        return clean;
    }

    private void read() throws Exception {
        devices = new ArrayList<>();
        selected = null;
        if (!file.exists()) return;
        if (file.length() < 29 || file.length() > MAX_STORE_BYTES) throw new IllegalStateException("Invalid device store");
        byte[] envelope = Files.readAllBytes(file.toPath());
        if (envelope[0] != 1) throw new IllegalStateException("Unsupported device store");
        Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
        cipher.init(Cipher.DECRYPT_MODE, key, new GCMParameterSpec(128, Arrays.copyOfRange(envelope, 1, 13)));
        cipher.updateAAD(AAD);
        byte[] plain = cipher.doFinal(envelope, 13, envelope.length - 13);
        try {
            JSONObject root = new JSONObject(new String(plain, StandardCharsets.UTF_8));
            if (root.getInt("version") != 1) throw new IllegalStateException("Unsupported device store");
            JSONArray saved = root.getJSONArray("devices");
            if (saved.length() > MAX_DEVICES) throw new IllegalStateException("Too many saved devices");
            for (int i = 0; i < saved.length(); i++) {
                JSONObject item = saved.getJSONObject(i);
                Pairing pairing = Pairing.fromJson(item.getJSONObject("pairing"));
                String id = item.getString("id");
                if (!id.equals(pairing.identity()) || find(id) != null) throw new IllegalStateException("Invalid device identity");
                devices.add(new Device(id, validName(item.getString("name")), pairing));
            }
            selected = root.isNull("selected") ? null : root.getString("selected");
            if (selected != null && find(selected) == null) throw new IllegalStateException("Invalid selected device");
        } finally { Arrays.fill(plain, (byte) 0); }
    }

    private void persist(List<Device> next, String nextSelected) {
        File temporary = null;
        byte[] plain = null;
        try {
            JSONObject root = new JSONObject().put("version", 1).put("selected", nextSelected == null ? JSONObject.NULL : nextSelected);
            JSONArray entries = new JSONArray();
            for (Device device : next) entries.put(new JSONObject().put("id", device.id).put("name", device.name).put("pairing", device.pairing.toJson()));
            root.put("devices", entries);
            plain = root.toString().getBytes(StandardCharsets.UTF_8);
            if (plain.length > MAX_STORE_BYTES - 29) throw new IllegalStateException("Device store is full");
            Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
            // Android Keystore generates a fresh random IV for each encryption.
            cipher.init(Cipher.ENCRYPT_MODE, key);
            cipher.updateAAD(AAD);
            byte[] encrypted = cipher.doFinal(plain);
            byte[] iv = cipher.getIV();
            if (iv.length != 12) throw new IllegalStateException("Unsupported encryption parameters");
            File directory = file.getParentFile();
            if (!directory.isDirectory() && !directory.mkdirs()) throw new IllegalStateException("Device storage unavailable");
            temporary = File.createTempFile("paired-devices-", ".pending", directory);
            try (FileOutputStream output = new FileOutputStream(temporary)) {
                output.write(1); output.write(iv); output.write(encrypted); output.getFD().sync();
            }
            Files.move(temporary.toPath(), file.toPath(), StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING);
            devices = new ArrayList<>(next);
            selected = nextSelected;
        } catch (Exception unavailable) { throw new IllegalStateException("Saved devices could not be updated"); }
        finally {
            if (plain != null) Arrays.fill(plain, (byte) 0);
            if (temporary != null && temporary.exists()) temporary.delete();
        }
    }

    private static SecretKey loadKey(boolean mayCreate) throws Exception {
        KeyStore store = KeyStore.getInstance("AndroidKeyStore");
        store.load(null);
        if (store.containsAlias(KEY_ALIAS)) return (SecretKey) store.getKey(KEY_ALIAS, null);
        if (!mayCreate) throw new IllegalStateException("Device encryption key unavailable");
        KeyGenerator generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore");
        generator.init(new KeyGenParameterSpec.Builder(KEY_ALIAS, KeyProperties.PURPOSE_ENCRYPT | KeyProperties.PURPOSE_DECRYPT)
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setKeySize(256).setRandomizedEncryptionRequired(true).build());
        return generator.generateKey();
    }
}
