package com.chekusu.sofatap.controller;

import org.json.JSONObject;
import org.junit.Test;
import static org.junit.Assert.*;

public class PairingTest {
    private static final String TOKEN = "A".repeat(43), PIN = "AB".repeat(32);
    static String link(boolean tv) { return "sofatap://" + (tv ? "tv" : "pair") + "?host=192.168.1.2&port=53319&token=" + TOKEN + "&fingerprint=" + PIN; }
    static Pairing pairing(boolean tv) { return Pairing.parse(link(tv)); }

    @Test public void desktopMetadataAndLiteralPlusRoundTrip() {
        Pairing p = Pairing.parse(" \n" + link(false) + "&platform=macos&name=Living+Room%20Mac \n");
        assertFalse(p.isTv()); assertEquals("Living+Room Mac", p.name); assertEquals("macos", p.platform);
        assertEquals("computer:" + PIN.toLowerCase(), p.identity());
        assertEquals("wss://192.168.1.2:53319/control", p.endpoint());
        Pairing restored = Pairing.fromJson(p.toJson());
        assertEquals(p.identity(), restored.identity()); assertEquals(p.token, restored.token); assertEquals(p.name, restored.name);
    }

    @Test public void tvIdentitySurvivesTokenRotationAndAddressIsNotIdentity() {
        Pairing first = pairing(true), rotated = first.withToken("B".repeat(43));
        assertTrue(rotated.isTv()); assertEquals(first.identity(), rotated.identity()); assertNotEquals(first.token, rotated.token);
        Pairing moved = Pairing.parse(link(true).replace("192.168.1.2", "10.0.0.4"));
        assertEquals(first.identity(), moved.identity());
        assertNotEquals(pairing(false).identity(), first.identity());
        assertTrue(Pairing.fromJson(first.toJson()).isTv());
    }

    @Test public void desktopSupportsDnsAndIpv6WithoutGuessingTvRoutes() {
        assertEquals("living-room.local", Pairing.parse(link(false).replace("192.168.1.2", "Living-Room.local")).host);
        assertEquals("wss://[fd00::1234]:53319/control", Pairing.parse(link(false).replace("192.168.1.2", "fd00%3A%3A1234")).endpoint());
        assertEquals("::ffff:192.168.1.2", Pairing.parse(link(false).replace("192.168.1.2", "%3A%3Affff%3A192.168.1.2")).host);
        for (String host : new String[]{"127.0.0.1", "169.254.1.2", "8.8.8.8", "172.32.0.1", "192.168.01.2", "localhost", "[::1]", "::1"}) {
            assertThrows(host, IllegalArgumentException.class, () -> Pairing.parse(link(true).replace("192.168.1.2", host)));
        }
        assertEquals("172.16.0.1", Pairing.parse(link(true).replace("192.168.1.2", "172.16.0.1")).host);
    }

    @Test public void rejectsAmbiguousAuthorityAndDuplicateDecodedFields() {
        for (String bad : new String[]{link(false) + "&host=10.0.0.1", link(false) + "&%68ost=10.0.0.1",
            link(false) + "&unknown=1", link(false) + "#fragment", link(false).replace("//pair?", "//user@pair?"),
            link(false).replace("//pair?", "//pair:443?"), link(false).replace("//pair?", "//pair/?"),
            link(false).replace("sofatap:", "https:"), link(false).replace("host=", "HOST="), link(false) + "&name=%C0%AF"}) {
            assertThrows(IllegalArgumentException.class, () -> Pairing.parse(bad));
        }
    }

    @Test public void rejectsInjectedLabelsAndWrongPlatform() {
        for (String suffix : new String[]{"&name=%0Asecret", "&name=room%E2%80%AEtxt", "&name=%20%20", "&name=" + "字".repeat(81), "&platform=androidtv"}) {
            assertThrows(IllegalArgumentException.class, () -> Pairing.parse(link(false) + suffix));
        }
        assertThrows(IllegalArgumentException.class, () -> Pairing.parse(link(true) + "&platform=windows"));
        assertThrows(IllegalArgumentException.class, () -> Pairing.parse(link(false).replace("53319", "65536")));
        assertThrows(IllegalArgumentException.class, () -> pairing(true).withToken("A".repeat(42)));
        assertThrows(IllegalArgumentException.class, () -> Pairing.parse(link(false).replace(PIN, "G".repeat(64))));
    }

    @Test public void storedCredentialsAreRevalidated() throws Exception {
        JSONObject stored = pairing(true).toJson();
        stored.put("host", "public.example.com");
        assertThrows(IllegalArgumentException.class, () -> Pairing.fromJson(stored));
        JSONObject invalidPort = pairing(false).toJson().put("port", 443.5);
        assertThrows(IllegalArgumentException.class, () -> Pairing.fromJson(invalidPort));
        JSONObject invalidToken = pairing(false).toJson().put("token", JSONObject.NULL);
        assertThrows(IllegalArgumentException.class, () -> Pairing.fromJson(invalidToken));
        JSONObject invalidUnicode = pairing(false).toJson().put("name", "\uD800");
        assertThrows(IllegalArgumentException.class, () -> Pairing.fromJson(invalidUnicode));
    }
}
