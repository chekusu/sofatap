#!/bin/bash
# Explicit disposable Android emulator only. Never connects to a TV or host desktop.
set -euo pipefail
ANDROID_PROJECT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
PROBE_SERIAL="${1:-}"
[[ "$PROBE_SERIAL" =~ ^emulator-[0-9]+$ ]] || { echo 'Pass an explicit disposable emulator serial (for example emulator-5584).' >&2; exit 2; }
PROBE_ADB="${ANDROID_HOME:?Set ANDROID_HOME}/platform-tools/adb"
[[ "$("$PROBE_ADB" -s "$PROBE_SERIAL" shell getprop ro.kernel.qemu | tr -d '\r')" == '1' ]] || { echo 'Refusing a non-emulator target.' >&2; exit 2; }
"$PROBE_ADB" -s "$PROBE_SERIAL" install -r "$ANDROID_PROJECT/receiver/build/outputs/apk/debug/receiver-debug.apk"
"$PROBE_ADB" -s "$PROBE_SERIAL" install -r "$ANDROID_PROJECT/receiver/build/outputs/apk/androidTest/debug/receiver-debug-androidTest.apk"
PROBE_RESULT="$(mktemp)"
trap 'rm -f "$PROBE_RESULT"' EXIT
"$PROBE_ADB" -s "$PROBE_SERIAL" shell am instrument -w -e disposableEmulator yes \
    com.chekusu.sofatap.tv.test/androidx.test.runner.AndroidJUnitRunner | tee "$PROBE_RESULT"
# am instrument can exit zero even when JUnit fails.
grep -q '^OK (28 tests)' "$PROBE_RESULT"
! grep -Eq 'FAILURES|INSTRUMENTATION_FAILED|Process crashed' "$PROBE_RESULT"
