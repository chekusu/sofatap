#!/bin/bash
# Real Bonjour discovery only; no credentials or OS input.
set -euo pipefail
REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
PEER_STAGE="$(mktemp -d "${TMPDIR:-/tmp}/sofatap-peer-discovery.XXXXXX")"
trap 'rm -rf "$PEER_STAGE"' EXIT
xcrun swiftc -warnings-as-errors \
  "$REPO_ROOT/ios/SofaTap/Core/PeerTransportDiscovery.swift" \
  "$REPO_ROOT/tests/PeerDiscoveryTests.swift" -o "$PEER_STAGE/tests"
python3 - "$PEER_STAGE/tests" <<'PY'
import subprocess,sys
subprocess.run([sys.argv[1]],check=True,timeout=15)
PY
