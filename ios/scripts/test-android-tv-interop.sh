#!/bin/bash
# Real native Swift URLSession/PinnedSessionDelegate -> production Java receiver.
# Binds one local private IPv4 interface; the injected receiver only counts input.
# No TV, phone, Keychain, browser, display changes or desktop input are involved.
set -euo pipefail
umask 077
REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
INTEROP_STAGE="$(mktemp -d "${TMPDIR:-/tmp}/sofatap-android-interop.XXXXXX")"
INTEROP_PID=""
cleanup() {
    if [[ -n "$INTEROP_PID" ]]; then
        touch "$INTEROP_STAGE/stop"
        kill "$INTEROP_PID" 2>/dev/null || true
        wait "$INTEROP_PID" 2>/dev/null || true
    fi
    rm -rf "$INTEROP_STAGE"
}
trap cleanup EXIT
INTEROP_JAVA="${SOFATAP_JAVA_HOME:+$SOFATAP_JAVA_HOME/bin/}java"
INTEROP_JAVAC="${SOFATAP_JAVA_HOME:+$SOFATAP_JAVA_HOME/bin/}javac"
"$INTEROP_JAVA" -version >"$INTEROP_STAGE/java.log" 2>&1 || {
    echo 'Java 17+ is required. Set SOFATAP_JAVA_HOME to the JDK directory.' >&2
    exit 1
}
INTEROP_CLASSPATH="$(python3 - "${GRADLE_USER_HOME:-$HOME/.gradle}/caches/modules-2/files-2.1" <<'PY'
from pathlib import Path
import sys
cache = Path(sys.argv[1])
modules = ['org.json/json/20250517', 'com.squareup.okhttp3/okhttp/4.12.0',
           'com.squareup.okhttp3/okhttp-tls/4.12.0', 'com.squareup.okio/okio-jvm/3.6.0',
           'org.jetbrains.kotlin/kotlin-stdlib/1.9.10',
           'org.bouncycastle/bcpkix-jdk15to18/1.86', 'org.bouncycastle/bcprov-jdk15to18/1.86',
           'org.bouncycastle/bcutil-jdk15to18/1.86']
jars = []
for module in modules:
    found = sorted((cache / module).glob('*/*.jar'))
    if len(found) != 1:
        raise SystemExit('Missing or ambiguous JVM test dependency. Run Android testDebugUnitTest first: ' + module)
    jars.append(str(found[0]))
print(':'.join(jars))
PY
)"
INTEROP_HOST="$(python3 - "${SOFATAP_ANDROID_FIXTURE_HOST:-}" <<'PY'
import ipaddress, re, subprocess, sys
private = [ipaddress.ip_network(x) for x in ['10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16']]
output = subprocess.check_output(['/sbin/ifconfig'], text=True)
assigned = re.findall(r'\binet (\d+\.\d+\.\d+\.\d+)\b', output)
candidates = [sys.argv[1]] if sys.argv[1] else assigned
for host in candidates:
    if host in assigned and any(ipaddress.ip_address(host) in network for network in private):
        print(host)
        break
else:
    raise SystemExit('A local RFC1918 IPv4 interface is required; no public or loopback endpoint is admitted.')
PY
)"
mkdir "$INTEROP_STAGE/classes"
INTEROP_SOURCE="$REPO_ROOT/android/receiver/src/main/java/com/chekusu/sofatap/tv"
"$INTEROP_JAVAC" -J-Xmx128m --release 17 -cp "$INTEROP_CLASSPATH" -d "$INTEROP_STAGE/classes" \
    "$INTEROP_SOURCE/WebSocketCodec.java" "$INTEROP_SOURCE/TVProtocol.java" "$INTEROP_SOURCE/TVAppShortcuts.java" \
    "$INTEROP_SOURCE/PairingAuthority.java" "$INTEROP_SOURCE/ReceiverServer.java" \
    "$INTEROP_SOURCE/ReceiverCertificate.java" \
    "$REPO_ROOT/android/receiver/src/test/java/com/chekusu/sofatap/tv/AndroidTVInteropFixture.java"
xcrun --sdk macosx swiftc -parse-as-library -swift-version 5 \
    -target "$(uname -m)-apple-macosx14.0" \
    "$REPO_ROOT/ios/SofaTap/Core/SavedDevice.swift" \
    "$REPO_ROOT/ios/SofaTap/Core/Pairing.swift" \
    "$REPO_ROOT/ios/SofaTap/Core/TV/"AndroidTV*.swift \
    "$REPO_ROOT/tests/AndroidTVInteropTests.swift" \
    -o "$INTEROP_STAGE/android-interop-tests"
"$INTEROP_JAVA" -Xmx128m -cp "$INTEROP_STAGE/classes:$INTEROP_CLASSPATH" \
    com.chekusu.sofatap.tv.AndroidTVInteropFixture "$INTEROP_HOST" "$INTEROP_STAGE" \
    >"$INTEROP_STAGE/fixture.log" 2>&1 &
INTEROP_PID=$!
for ((INTEROP_TRY=0; INTEROP_TRY<100; INTEROP_TRY++)); do
    [[ -f "$INTEROP_STAGE/fixture.json" ]] && break
    if ! kill -0 "$INTEROP_PID" 2>/dev/null; then
        echo 'Java fixture failed to start.' >&2
        cat "$INTEROP_STAGE/fixture.log" >&2
        exit 1
    fi
    sleep 0.1
done
[[ -f "$INTEROP_STAGE/fixture.json" ]] || { echo 'Java fixture startup timed out.' >&2; exit 1; }
"$INTEROP_STAGE/android-interop-tests" "$INTEROP_STAGE"
