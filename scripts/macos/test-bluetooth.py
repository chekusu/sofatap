#!/usr/bin/env python3
"""Bounded BLE stream and real TLS over simulated ATT. No Bluetooth hardware or OS input."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
OUTPUT = ROOT / "artifacts/pointer-development/bluetooth-checks.json"
SOURCES = ["ios/SofaTap/Core/BluetoothTransport.swift", "tests/BluetoothTransportTests.swift"]
with tempfile.TemporaryDirectory(prefix="sofatap-ble-checks-") as tmp:
    binary = str(Path(tmp) / "checks")
    subprocess.run(["xcrun", "swiftc", "-warnings-as-errors", "-parse-as-library",
                    *[str(ROOT / path) for path in SOURCES], "-o", binary], check=True, timeout=90)
    result = subprocess.run([binary], capture_output=True, text=True, check=True, timeout=10)
    print(result.stdout.strip())
    subprocess.run(["python3", str(ROOT / "tests/peer-tls-bridge.py"), "--bluetooth-simulation"],
                   cwd=ROOT, check=True, timeout=150, env=os.environ.copy())
    tls = json.loads((OUTPUT.parent / "bluetooth-tls-simulation.json").read_text())
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_text(json.dumps({
        "schema": 1, "radioTested": False, "osInputInjected": False,
        "boundedStream": result.stdout.strip(), "tls": tls,
        "sourceSHA256": {path: hashlib.sha256((ROOT / path).read_bytes()).hexdigest() for path in SOURCES},
        "hardwareAcceptance": "pending",
    }, indent=2) + "\n")
    print("Receipt:", OUTPUT.relative_to(ROOT))
