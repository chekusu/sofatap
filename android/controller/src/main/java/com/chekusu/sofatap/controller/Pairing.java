package com.chekusu.sofatap.controller;

import org.json.JSONObject;
import java.io.ByteArrayOutputStream;
import java.net.InetAddress;
import java.net.URI;
import java.nio.ByteBuffer;
import java.nio.charset.CodingErrorAction;
import java.nio.charset.StandardCharsets;
import java.util.HashMap;
import java.util.Locale;
import java.util.Map;
import java.util.Set;

/** A scanned credential is bound to one endpoint and certificate, not its display name. */
public final class Pairing {
    public final String host, token, fingerprint, platform, name;
    public final int port;
    private final boolean tv;
    private static final Set<String> FIELDS = Set.of("host", "port", "token", "fingerprint", "platform", "name");

    private Pairing(boolean tv, String host, int port, String token, String fingerprint, String platform, String name) {
        this.tv = tv; this.host = host; this.port = port; this.token = token;
        this.fingerprint = fingerprint; this.platform = platform; this.name = name;
    }

    public boolean isTv() { return tv; }
    public String identity() { return (tv ? "androidtv:" : "computer:") + fingerprint; }
    public String endpoint() {
        try { return new URI("wss", null, host, port, "/control", null, null).toASCIIString(); }
        catch (Exception invalid) { throw invalid(); }
    }

    public static Pairing parse(String raw) {
        if (raw == null || !validUnicode(raw)) throw invalid();
        String value = strip(raw);
        if (value.getBytes(StandardCharsets.UTF_8).length > 2048) throw invalid();
        try {
            URI uri = new URI(value);
            if (!"sofatap".equalsIgnoreCase(uri.getScheme()) || uri.getRawUserInfo() != null || uri.getPort() != -1 ||
                uri.getRawFragment() != null || !"".equals(uri.getRawPath()) ||
                !("pair".equals(uri.getRawAuthority()) || "tv".equals(uri.getRawAuthority()))) throw invalid();
            String query = uri.getRawQuery();
            if (query == null) throw invalid();
            String[] pairs = query.split("&", -1);
            if (pairs.length < 4 || pairs.length > 6) throw invalid();
            Map<String, String> fields = new HashMap<>();
            for (String pair : pairs) {
                int delimiter = pair.indexOf('=');
                if (delimiter < 1) throw invalid();
                String key = decode(pair.substring(0, delimiter));
                String field = decode(pair.substring(delimiter + 1));
                if (!FIELDS.contains(key) || fields.put(key, field) != null) throw invalid();
            }
            return validate("tv".equals(uri.getRawAuthority()), fields);
        } catch (IllegalArgumentException bad) { throw bad; }
        catch (Exception bad) { throw invalid(); }
    }

    private static Pairing validate(boolean tv, Map<String, String> fields) {
        String host = fields.get("host"), port = fields.get("port"), token = fields.get("token"), fingerprint = fields.get("fingerprint");
        if (host == null || !(tv ? privateIPv4(host) : validHost(host)) || port == null || !port.matches("[0-9]+") ||
            token == null || !token.matches(tv ? "[A-Za-z0-9_-]{43}" : "[A-Za-z0-9_-]{32,256}") ||
            fingerprint == null || !fingerprint.matches("[A-Fa-f0-9]{64}")) throw invalid();
        final int number;
        try { number = Integer.parseInt(port); } catch (NumberFormatException bad) { throw invalid(); }
        if (number < 1 || number > 65535) throw invalid();
        String platform = fields.get("platform"), name = fields.get("name");
        if (platform != null && !(tv ? Set.of("androidtv") : Set.of("windows", "macos", "linux")).contains(platform)) throw invalid();
        if (name != null) {
            if (!validUnicode(name) || name.codePoints().anyMatch(Pairing::isControl)) throw invalid();
            name = strip(name);
            if (name.isEmpty() || name.codePointCount(0, name.length()) > 80 || name.getBytes(StandardCharsets.UTF_8).length > 256) throw invalid();
        }
        return new Pairing(tv, host.toLowerCase(Locale.ROOT), number, token, fingerprint.toLowerCase(Locale.ROOT), platform, name);
    }

    public Pairing withToken(String replacement) {
        Map<String, String> fields = fields(); fields.put("token", replacement);
        return validate(tv, fields);
    }

    public JSONObject toJson() {
        try {
            JSONObject result = new JSONObject().put("kind", tv ? "androidtv" : "computer");
            for (Map.Entry<String, String> entry : fields().entrySet()) result.put(entry.getKey(), entry.getValue());
            // The stored port is numeric; URL parsing still requires decimal digits.
            return result.put("port", port);
        } catch (Exception bad) { throw invalid(); }
    }

    public static Pairing fromJson(JSONObject value) {
        if (value == null) throw invalid();
        Object kind = value.opt("kind");
        if (!"computer".equals(kind) && !"androidtv".equals(kind)) throw invalid();
        Map<String, String> fields = new HashMap<>();
        for (String key : FIELDS) {
            if (!value.has(key)) continue;
            Object field = value.opt(key);
            if (key.equals("port")) {
                if (!(field instanceof Number n) || !Double.isFinite(n.doubleValue()) || n.doubleValue() != n.intValue()) throw invalid();
                fields.put(key, Integer.toString(n.intValue()));
            } else {
                if (!(field instanceof String)) throw invalid();
                fields.put(key, (String) field);
            }
        }
        return validate("androidtv".equals(kind), fields);
    }

    private Map<String, String> fields() {
        Map<String, String> fields = new HashMap<>();
        fields.put("host", host); fields.put("port", Integer.toString(port)); fields.put("token", token); fields.put("fingerprint", fingerprint);
        if (platform != null) fields.put("platform", platform);
        if (name != null) fields.put("name", name);
        return fields;
    }

    private static boolean validHost(String host) {
        if (host.isEmpty() || host.length() > 253 || host.chars().anyMatch(c -> c > 127)) return false;
        if (host.indexOf(':') >= 0) {
            if (!host.matches("[0-9a-fA-F:.]+")) return false;
            // The character allowlist and colon prevent DNS resolution. Java represents
            // valid IPv4-mapped IPv6 addresses as Inet4Address, unlike inet_pton.
            try { InetAddress.getByName(host); return true; }
            catch (Exception bad) { return false; }
        }
        for (String label : host.split("\\.", -1)) {
            if (label.isEmpty() || label.length() > 63 || label.startsWith("-") || label.endsWith("-") || !label.matches("[A-Za-z0-9-]+")) return false;
        }
        return true;
    }

    private static boolean privateIPv4(String host) {
        String[] pieces = host.split("\\.", -1);
        if (pieces.length != 4) return false;
        int[] bytes = new int[4];
        for (int index = 0; index < 4; index++) {
            if (!pieces[index].matches("0|[1-9][0-9]{0,2}")) return false;
            bytes[index] = Integer.parseInt(pieces[index]);
            if (bytes[index] > 255) return false;
        }
        return bytes[0] == 10 || bytes[0] == 172 && bytes[1] >= 16 && bytes[1] <= 31 || bytes[0] == 192 && bytes[1] == 168;
    }

    private static String decode(String encoded) throws Exception {
        ByteArrayOutputStream bytes = new ByteArrayOutputStream();
        for (int index = 0; index < encoded.length();) {
            if (encoded.charAt(index) == '%') {
                if (index + 2 >= encoded.length()) throw invalid();
                int high = Character.digit(encoded.charAt(index + 1), 16), low = Character.digit(encoded.charAt(index + 2), 16);
                if (high < 0 || low < 0) throw invalid();
                bytes.write((high << 4) | low); index += 3;
            } else {
                int point = encoded.codePointAt(index);
                bytes.write(new String(Character.toChars(point)).getBytes(StandardCharsets.UTF_8));
                index += Character.charCount(point);
            }
        }
        return StandardCharsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT)
            .onUnmappableCharacter(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(bytes.toByteArray())).toString();
    }

    static boolean isControl(int point) { return Character.isISOControl(point) || Character.getType(point) == Character.FORMAT; }
    static boolean validUnicode(String value) {
        for (int index = 0; index < value.length(); index++) {
            char c = value.charAt(index);
            if (Character.isHighSurrogate(c)) { if (++index >= value.length() || !Character.isLowSurrogate(value.charAt(index))) return false; }
            else if (Character.isLowSurrogate(c)) return false;
        }
        return true;
    }
    private static String strip(String value) {
        int first = 0, last = value.length();
        while (first < last) { int c = value.codePointAt(first); if (!space(c)) break; first += Character.charCount(c); }
        while (last > first) { int c = value.codePointBefore(last); if (!space(c)) break; last -= Character.charCount(c); }
        return value.substring(first, last);
    }
    private static boolean space(int point) { return Character.isWhitespace(point) || Character.isSpaceChar(point); }
    private static IllegalArgumentException invalid() { return new IllegalArgumentException("Invalid Sofatap pairing code"); }
}
