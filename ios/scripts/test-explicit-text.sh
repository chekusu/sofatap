#!/bin/bash
# Exercise production ControllerModel offscreen via Mac Catalyst and an injected
# recording transport. No app window, pairing, network session or OS input.
set -euo pipefail
REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
EXPLICIT_SDK="$(xcrun --sdk macosx --show-sdk-path)"
EXPLICIT_STAGE="$(mktemp -d "${TMPDIR:-/tmp}/sofatap-explicit-tests.XXXXXX")"
trap 'rm -rf "$EXPLICIT_STAGE"' EXIT
xcrun --sdk macosx swiftc -parse-as-library -swift-version 5 \
    -D SOFATAP_CONTROLLER_TESTING \
    -target "$(uname -m)-apple-ios17.0-macabi" -sdk "$EXPLICIT_SDK" \
    -F "$EXPLICIT_SDK/System/iOSSupport/System/Library/Frameworks" \
    -I "$EXPLICIT_SDK/System/iOSSupport/usr/include" \
    "$REPO_ROOT/ios/SofaTap/Core/ControllerModel.swift" \
    "$REPO_ROOT/ios/SofaTap/Core/PeerTransportDiscovery.swift" \
    "$REPO_ROOT/ios/SofaTap/Core/PeerTLSBridge.swift" \
    "$REPO_ROOT/ios/SofaTap/Core/SavedDevice.swift" \
    "$REPO_ROOT/ios/SofaTap/Core/Pairing.swift" \
    "$REPO_ROOT/ios/SofaTap/Core/ReceiverState.swift" \
    "$REPO_ROOT/ios/SofaTap/Core/ComputerUnlockController.swift" \
    "$REPO_ROOT/ios/SofaTap/Core/UnlockCredentialVault.swift" \
    "$REPO_ROOT/ios/SofaTap/Core/UnlockProtocol.swift" \
    "$REPO_ROOT/ios/SofaTap/Views/NativeControls.swift" \
    "$REPO_ROOT/ios/SofaTap/Views/TouchParticleRenderer.swift" \
    "$REPO_ROOT/ios/SofaTap/Core/TouchGestureState.swift" \
    "$REPO_ROOT/ios/SofaTap/Core/GestureConfiguration.swift" \
    "$REPO_ROOT/tests/ExplicitTextControllerTests.swift" \
    -o "$EXPLICIT_STAGE/explicit-text-tests"
"$EXPLICIT_STAGE/explicit-text-tests"
