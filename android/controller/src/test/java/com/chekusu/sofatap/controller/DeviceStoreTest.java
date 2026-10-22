package com.chekusu.sofatap.controller;

import static org.junit.Assert.*;
import org.junit.Rule;
import org.junit.Test;
import org.junit.rules.TemporaryFolder;
import java.io.File;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.Arrays;
import javax.crypto.KeyGenerator;
import javax.crypto.SecretKey;

public class DeviceStoreTest {
    @Rule public TemporaryFolder folder = new TemporaryFolder();
    private SecretKey key() throws Exception { KeyGenerator generator = KeyGenerator.getInstance("AES"); generator.init(256); return generator.generateKey(); }
    private Pairing pairing(String host, char fingerprint, String token) {
        return Pairing.parse("sofatap://pair?host=" + host + "&port=53319&token=" + token + "&fingerprint=" + String.valueOf(fingerprint).repeat(64) + "&name=Living%20room");
    }
    private String token(char value) { return String.valueOf(value).repeat(43); }

    @Test public void credentialsAndNamesAreEncryptedAndSurviveReload() throws Exception {
        File file = new File(folder.getRoot(), "devices.enc"); SecretKey key = key();
        DeviceStore store = new DeviceStore(file, key);
        DeviceStore.Device device = store.save(pairing("192.168.1.7", 'a', token('b')));
        store.rename(device.id, "卧室の PC");
        String disk = new String(Files.readAllBytes(file.toPath()), StandardCharsets.UTF_8);
        assertFalse(disk.contains(token('b'))); assertFalse(disk.contains("192.168.1.7")); assertFalse(disk.contains("卧室"));
        DeviceStore restored = new DeviceStore(file, key);
        assertEquals(device.id, restored.selectedId()); assertEquals("卧室の PC", restored.selected().name);
        assertEquals(token('b'), restored.selected().pairing.token);
    }

    @Test public void rotatingTokenOrAddressDeduplicatesCertificateAndPreservesName() throws Exception {
        File file = new File(folder.getRoot(), "devices.enc"); DeviceStore store = new DeviceStore(file, key());
        DeviceStore.Device original = store.save(pairing("192.168.1.7", 'a', token('b')));
        store.rename(original.id, "My PC");
        DeviceStore.Device rotated = store.save(pairing("192.168.1.8", 'a', token('c')));
        assertEquals(1, store.list().size()); assertEquals(original.id, rotated.id); assertEquals("My PC", rotated.name);
        assertEquals("192.168.1.8", rotated.pairing.host); assertEquals(token('c'), rotated.pairing.token);
    }

    @Test public void differentCertificatesRemainSeparateAndRemovalClearsSelection() throws Exception {
        File file = new File(folder.getRoot(), "devices.enc"); SecretKey key = key(); DeviceStore store = new DeviceStore(file, key);
        String first = store.save(pairing("192.168.1.7", 'a', token('b'))).id;
        String second = store.save(pairing("192.168.1.7", 'd', token('e'))).id;
        assertEquals(2, store.list().size()); store.select(first); store.remove(first);
        assertNull(store.selected()); assertEquals(second, store.list().get(0).id);
        assertNull(new DeviceStore(file, key).selected());
    }

    @Test public void corruptedCiphertextIsPreservedInsteadOfSilentlyReset() throws Exception {
        File file = new File(folder.getRoot(), "devices.enc"); SecretKey key = key();
        new DeviceStore(file, key).save(pairing("192.168.1.7", 'a', token('b')));
        byte[] damaged = Files.readAllBytes(file.toPath()); damaged[damaged.length - 1] ^= 1; Files.write(file.toPath(), damaged);
        try { new DeviceStore(file, key); fail("Corrupted store opened"); }
        catch (IllegalStateException expected) { assertFalse(expected.getMessage().contains(token('b'))); }
        assertArrayEquals(damaged, Files.readAllBytes(file.toPath()));
    }

    @Test public void missingOrWrongEncryptionKeyDoesNotReplaceFile() throws Exception {
        File file = new File(folder.getRoot(), "devices.enc"); SecretKey original = key();
        new DeviceStore(file, original).save(pairing("192.168.1.7", 'a', token('b')));
        byte[] before = Files.readAllBytes(file.toPath());
        try { new DeviceStore(file, key()); fail("Wrong key accepted"); } catch (IllegalStateException expected) { }
        assertArrayEquals(before, Files.readAllBytes(file.toPath()));
        assertEquals(1, new DeviceStore(file, original).list().size());
    }

    @Test public void freshNonceForEverySaveAndInvalidMutationIsNonDestructive() throws Exception {
        File file = new File(folder.getRoot(), "devices.enc"); DeviceStore store = new DeviceStore(file, key());
        String id = store.save(pairing("192.168.1.7", 'a', token('b'))).id;
        byte[] first = Files.readAllBytes(file.toPath()); store.select(id);
        byte[] second = Files.readAllBytes(file.toPath()); assertFalse(Arrays.equals(first, second));
        try { store.rename(id, "bad\nname"); fail("Invalid name accepted"); } catch (IllegalArgumentException expected) { }
        try { store.select("missing"); fail("Unknown device selected"); } catch (IllegalArgumentException expected) { }
        assertArrayEquals(second, Files.readAllBytes(file.toPath()));
        assertEquals(id, store.selectedId());
    }

    @Test public void failedAtomicWriteDoesNotMutateMemory() throws Exception {
        File directory = folder.newFolder("blocked"); File file = new File(directory, "devices.enc");
        DeviceStore store = new DeviceStore(file, key());
        assertTrue(directory.delete()); assertTrue(directory.createNewFile());
        try { store.save(pairing("192.168.1.7", 'a', token('b'))); fail("Write should fail"); }
        catch (IllegalStateException expected) { }
        assertTrue(store.list().isEmpty()); assertNull(store.selected());
    }
}
