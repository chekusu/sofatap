#!/bin/bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/sofatap-peer-owner.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
xcrun swiftc -parse-as-library -swift-version 5 -D SOFATAP_RECEIVER_TESTING \
  "$ROOT/desktop/macos/ReceiverController.swift" "$ROOT/desktop/macos/ReceiverProtocol.swift" \
  "$ROOT/desktop/macos/ReceiverPipeReader.swift" "$ROOT/desktop/macos/ReceiverStoreEnvironment.swift" \
  "$ROOT/ios/SofaTap/Core/BluetoothTransport.swift" \
  "$ROOT/desktop/macos/MacPeerRelay.swift" "$ROOT/desktop/macos/tests/ReceiverPeerLifecycleTests.swift" \
  -o "$STAGE/tests"
python3 - "$STAGE/tests" <<'PYTHON'
import subprocess,sys
subprocess.run([sys.argv[1]],check=True,timeout=15)
PYTHON
