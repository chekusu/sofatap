#!/bin/bash
# Exercise desktop volume and pointer speed offscreen via Mac Catalyst and an injected
# recording transport. No app window, pairing, network session or OS input.
set -euo pipefail
REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
CONTROLS_SDK="$(xcrun --sdk macosx --show-sdk-path)"
CONTROLS_STAGE="$(mktemp -d "${TMPDIR:-/tmp}/sofatap-desktop-controls-tests.XXXXXX")"
trap 'rm -rf "$CONTROLS_STAGE"' EXIT
xcrun --sdk macosx swiftc -parse-as-library -swift-version 5 \
    -D SOFATAP_CONTROLLER_TESTING \
    -target "$(uname -m)-apple-ios17.0-macabi" -sdk "$CONTROLS_SDK" \
    -F "$CONTROLS_SDK/System/iOSSupport/System/Library/Frameworks" \
    -I "$CONTROLS_SDK/System/iOSSupport/usr/include" \
    "$REPO_ROOT/ios/SofaTap/Core/ControllerModel.swift" \
    "$REPO_ROOT/ios/SofaTap/Core/PeerTransportDiscovery.swift" \
    "$REPO_ROOT/ios/SofaTap/Core/PeerTLSBridge.swift" \
    "$REPO_ROOT/ios/SofaTap/Core/BluetoothTransport.swift" \
    "$REPO_ROOT/ios/SofaTap/Core/SavedDevice.swift" \
    "$REPO_ROOT/ios/SofaTap/Core/Pairing.swift" \
    "$REPO_ROOT/ios/SofaTap/Core/ReceiverState.swift" \
    "$REPO_ROOT/ios/SofaTap/Core/ComputerUnlockController.swift" \
    "$REPO_ROOT/ios/SofaTap/Core/UnlockCredentialVault.swift" \
    "$REPO_ROOT/ios/SofaTap/Core/UnlockProtocol.swift" \
    "$REPO_ROOT/tests/DesktopControlsTests.swift" \
    -o "$CONTROLS_STAGE/controller-desktop-controls-tests"
"$CONTROLS_STAGE/controller-desktop-controls-tests"
