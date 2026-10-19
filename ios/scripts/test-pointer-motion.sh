#!/bin/bash
set -euo pipefail
REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
POINTER_STAGE="$(mktemp -d "${TMPDIR:-/tmp}/sofatap-pointer-tests.XXXXXX")"
trap 'rm -rf "$POINTER_STAGE"' EXIT
xcrun swiftc -warnings-as-errors \
    "$REPO_ROOT/ios/SofaTap/Core/GestureConfiguration.swift" \
    "$REPO_ROOT/ios/SofaTap/Core/TouchGestureState.swift" \
    "$REPO_ROOT/ios/SofaTap/Core/PointerTiming.swift" \
    "$REPO_ROOT/tests/PointerMotionTests.swift" -o "$POINTER_STAGE/pointer"
"$POINTER_STAGE/pointer"
xcrun swiftc -warnings-as-errors \
    "$REPO_ROOT/ios/SofaTap/Core/GestureConfiguration.swift" \
    "$REPO_ROOT/ios/SofaTap/Core/TouchGestureState.swift" \
    "$REPO_ROOT/tests/TouchGestureTests.swift" -o "$POINTER_STAGE/gestures"
"$POINTER_STAGE/gestures"
