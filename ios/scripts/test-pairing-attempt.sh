#!/bin/bash
# Production add-device guard and controller lifecycle, with memory storage and
# a recording connection adapter. No UI, Keychain, network or desktop input.
set -euo pipefail
REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
PAIRING_SDK="$(xcrun --sdk macosx --show-sdk-path)"
PAIRING_STAGE="$(mktemp -d "${TMPDIR:-/tmp}/sofatap-pairing-attempt-tests.XXXXXX")"
trap 'rm -rf "$PAIRING_STAGE"' EXIT
xcrun --sdk macosx swiftc -parse-as-library -swift-version 5 \
    -D SOFATAP_CONTROLLER_TESTING \
    -target "$(uname -m)-apple-ios17.0-macabi" -sdk "$PAIRING_SDK" \
    -F "$PAIRING_SDK/System/iOSSupport/System/Library/Frameworks" \
    -I "$PAIRING_SDK/System/iOSSupport/usr/include" \
    "$REPO_ROOT/ios/SofaTap/Core/ControllerModel.swift" \
    "$REPO_ROOT/ios/SofaTap/Core/PeerTransportDiscovery.swift" \
    "$REPO_ROOT/ios/SofaTap/Core/PeerTLSBridge.swift" \
    "$REPO_ROOT/ios/SofaTap/Core/BluetoothTransport.swift" \
    "$REPO_ROOT/ios/SofaTap/Core/SavedDevice.swift" \
    "$REPO_ROOT/ios/SofaTap/Core/Pairing.swift" \
    "$REPO_ROOT/ios/SofaTap/Core/PairingCode.swift" \
    "$REPO_ROOT/ios/SofaTap/Core/PairingAttemptState.swift" \
    "$REPO_ROOT/ios/SofaTap/Core/TV/AndroidTVControls.swift" \
    "$REPO_ROOT/ios/SofaTap/Core/TV/AndroidTVProtocol.swift" \
    "$REPO_ROOT/ios/SofaTap/Core/TV/AndroidTVPairingStore.swift" \
    "$REPO_ROOT/ios/SofaTap/Core/ReceiverState.swift" \
    "$REPO_ROOT/ios/SofaTap/Core/ComputerUnlockController.swift" \
    "$REPO_ROOT/ios/SofaTap/Core/UnlockCredentialVault.swift" \
    "$REPO_ROOT/ios/SofaTap/Core/UnlockProtocol.swift" \
    "$REPO_ROOT/ios/SofaTap/Views/NativeControls.swift" \
    "$REPO_ROOT/ios/SofaTap/Views/TouchParticleRenderer.swift" \
    "$REPO_ROOT/ios/SofaTap/Core/TouchGestureState.swift" \
    "$REPO_ROOT/ios/SofaTap/Core/GestureConfiguration.swift" \
    "$REPO_ROOT/tests/PairingAttemptTests.swift" \
    -o "$PAIRING_STAGE/pairing-attempt-tests"
"$PAIRING_STAGE/pairing-attempt-tests"
