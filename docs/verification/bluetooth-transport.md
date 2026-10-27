# Experimental Bluetooth transport

## Failure cases recorded before implementation

Physical Core Bluetooth cannot be emulated by a unit test. Isolated checks are
limited to the bounded byte transport and controller routing policy; hardware
acceptance remains required. The experiment preserves pinned TLS and the existing
receiver authentication/input protocol inside a BLE stream.

- Fragmentation at small ATT payload sizes changes, duplicates or loses bytes.
- A full transmit queue drops a TLS byte or grows without bound.
- A stale callback after disconnect reaches a new session.
- Bluetooth permission denial, power loss, missing receiver or unsubscribing leaves
  a continuation, socket or held button alive indefinitely.
- Switching routes replays pending gestures or silently falls back to Wi-Fi.
- An unrelated advertiser can obtain a pairing token by claiming the service UUID.
  Certificate pinning must still run before the HTTP authorization header is sent.
- A second controller steals the active stream, or malformed writes reach it.
- Local relay failure is mistaken for BLE success.
- Advertising remains enabled without user opt-in or after helper termination.
- Missing usage descriptions or sandbox entitlements prevent the packaged app
  from using Bluetooth.

## Acceptance plan

Use the same iPhone/Mac, gestures and sampling pipeline for ordinary Wi-Fi,
automatic peer Wi-Fi (verify the actual route), and explicit BLE. Measure response
latency distribution, longest pauses, reconnect behavior and drag release.
Bluetooth selection must never silently fall back to another route. Test denied
permission, Bluetooth disabled, out of range, app backgrounding, helper restart,
wrong certificate, and return to Wi-Fi. Do not claim a performance improvement
from a build, synthetic transport test or application ACK RTT alone.

Live input on the shared Mac requires verified virtual-display input isolation
as specified in AGENTS.md. Otherwise defer real mouse/keyboard injection and
record hardware acceptance as pending.

## Implementation and reproduction

- Base: upstream `chekusu/sofatap` main `28fafb2`. Development branch is intended
  for a PR from the contributor fork, not a direct upstream push.
- iPhone: pair using the existing QR flow, then choose **Bluetooth (beta)** in
  connection modes. Mac: turn on **蓝牙实验模式**. The switch defaults off each run;
  granting Bluetooth permission alone does not enable advertising on later runs.
- iPhone is the BLE central; Mac is a peripheral with one active subscriber.
  The service UUID is derived from the certificate fingerprint and a versioned
  namespace. This only scopes discovery; full TLS certificate/hostname checking
  and the existing bearer authentication remain mandatory.
- WSS/TLS bytes are fragmented through custom GATT write/notify characteristics.
  Writes use ATT responses for backpressure; input success still depends on the
  existing application ACK. There is no plaintext control service or HID emulation.
- Socket reads pause at BLE backpressure; buffers have a 64 KiB limit. Disconnect
  discards the stream and closes the helper connection. No pending input is replayed.
- BLE preparation has a 15 s deadline. Unsupported platforms, permission/power
  failures and discovery timeout show a retry notice without LAN fallback.
- BLE mode does not request lower connection intervals; initial results measure
  the platform defaults. It makes no performance promise compared with AWDL.
- Debug builds save `pointer-timing-ble.json`, `pointer-timing-peer.json`, and
  `pointer-timing-wifi.json` in app Documents. The latest snapshot also remains
  `pointer-timing.json` for existing harnesses. Each session resets histograms.
  These contain numeric timing and route labels, no input text or pairing tokens.
  Application ACK RTT is not touch-to-photon latency.

Run after building the Release dry-run host:

```sh
dotnet build host/SofaTap.Host.csproj -c Release
SOFATAP_DOTNET="$(command -v dotnet)" python3 scripts/macos/test-bluetooth.py
bash ios/scripts/test-pairing-attempt.sh
bash ios/scripts/test-drag-release.sh
bash scripts/macos/test-peer-lifecycle.sh
python3 ios/scripts/check-localizations.py
```

The reproducible receipt is `artifacts/pointer-development/bluetooth-checks.json`.
The ATT substitute tests real pinned TLS/WebSocket traffic, authentication
rejection and teardown using production socket/buffer code at 20/185/512-byte
payload sizes. It does **not** exercise Core Bluetooth delegates, radio scheduling,
Bluetooth permission dialogs or physical input. Those remain pending hardware
acceptance; no claim that BLE is smoother is supported by these checks.

## Local validation (2026-10-27)

- Failing checks were recorded before implementing bounded buffers and BLE route
  selection; an additional failing check preceded disabling AWDL discovery in BLE.
- Bounded stream: 1,210 assertions; connection lifecycle: 130 checks.
- Existing TLS/WebSocket integration: 69 dry-run checks.
- Existing drag/ACK recovery: 66; explicit text: 61; live text: 63; desktop controls: 27.
- Real TLS over simulated ATT: valid traffic at 20/185/512-byte boundaries, bad
  pin, hostname and token rejection, stopped bridge and stopped relay.
- Native Mac and Mac App Store conditional builds compile. iOS Debug simulator
  and unsigned physical-device targets build successfully. Twelve locale tables
  include the new mode, status, failure notice and Bluetooth permission text.
- No new app was installed or launched on physical devices. Core Bluetooth radio
  behavior, packaged permission prompts, UI appearance and physical pointer
  performance are not certified by these results.
