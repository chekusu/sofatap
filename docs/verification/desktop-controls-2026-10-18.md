# Desktop volume and pointer speed

Development implementation for [issue #11](https://github.com/chekusu/sofatap/issues/11), October 18, 2026. **Not released.** This adds free manual computer controls; it does not change TV controls or start voice automation.

## Behavior

- The computer remote's speaker button opens **Computer volume**: volume down, volume up, and toggle mute for the default playback output. Each volume tap changes the scalar by 5 percentage points within 0–100%; it preserves mute state. Toggle mute is a separate operation. The phone does not display an invented percentage or mute indicator.
- Windows uses `IAudioEndpointVolume` on the default multimedia render endpoint. macOS uses writable CoreAudio master controls, falling back to the output's writable channels. Outputs without writable volume and mute controls, including some digital outputs, report unavailable. Neither implementation synthesizes keyboard events or targets the foreground app.
- Linux uses the existing audio session through system-installed `wpctl` (WirePlumber/PipeWire) or `pactl` (PulseAudio or its PipeWire compatibility server). No shell or user-provided command is executed. Missing tools, unavailable audio, malformed replies, and failed writes are surfaced; a failed write never falls back to a second backend.
- **Gesture settings → Pointer speed** saves a computer-only multiplier from 0.25× to 3×, default 1×. It scales remote pointer movement, including drag movement, before the existing bounded motion queue. Scrolling keeps its existing units. The computer OS mouse preference is unchanged. Presets and reset restore 1×; old preference data loads as 1×. TV profiles always remain 1×.
- Volume requires a live, foreground desktop connection and an advertised capability. Older receivers, dry-run receivers and unavailable desktop input cannot accept phone volume commands. The phone allows one pending volume action and queues no repeats. Disconnect/timeout clears pending input and never replays volume on reconnection.

## Protocol

Additive protocol-v1 capability: `systemVolume: {"version": 1}` in hello and status ACKs. A status ACK with explicit `systemVolume: null` revokes a previously available capability. Omitted metadata on legacy ACKs preserves negotiated state.

Audio capability probes run in a single background task with a short-lived cache. Initial connections may acquire the capability on a later status ACK; stale results expire. A stalled audio service cannot block the receiver's normal ping, pointer or text processing. Each explicit volume action still revalidates the current default output and pins that output for its read/write sequence.

The only new action shape is `{"id":"<UUID>","type":"volume","command":"up"}`; `command` also permits `down` and `mute`. Unknown fields and values are rejected. The receiver caches both successful and failed ACKs by UUID and payload, so repeating a mute UUID cannot toggle it twice. Reusing that UUID for a different payload is rejected. Volume actions leave the live-text session and pointer-button ownership intact. Errors after a possibly successful native write require checking the actual computer volume before trying again.

## Validation

The regression suites use recording transports, fake audio endpoints and fixed-command process doubles. No test in this change adjusts the shared Mac's actual output volume, sends physical desktop input, or changes its displays.

- `bash ios/scripts/test-desktop-controls.sh`: phone capability gating, one command in flight, rejected/uncertain ACKs, actual JSON serialization, timeout/reconnect without replay, stale completion isolation, motion scaling/bounds, scroll independence and drag-tail order.
- `bash ios/scripts/test-custom-gestures.sh`: preference migration, persistence, malformed values, finite bounds, TV isolation, reset and existing gesture behavior.
- `tests/ReceiverStateTests.swift`: valid/invalid capability versions, legacy metadata and explicit revocation.
- Existing drag release, live-text, explicit-text and pairing-attempt suites cover interaction regressions.
- `python3 ios/scripts/check-localizations.py`: all 12 existing locales, keys, format placeholders and Swift string references.
- `bash ios/scripts/build-manual.sh device`: complete unprovisioned iPhone/iPad app compilation; no installation or upload.
- `dotnet run --project tests/host/SofaTap.Host.Tests.csproj -c Release`: strict protocol, deduplication, native adapter semantics and receiver transport checks with fake input/audio. Linux process tests cover fixed executable/arguments, audio parsing, process limits and no retry after uncertain writes.

GitHub CI runs the new phone suite and host tests alongside the existing macOS, Windows, Linux and Android checks. Exact head, results and independent-review findings are recorded on the PR.

## Remaining acceptance

Real iPhone/iPad visual layout and live audio-output tests on Windows, macOS and Linux are still required before release qualification. Offscreen SwiftUI `Form` rendering did not produce reliable screenshots, so it is not claimed as visual acceptance. This validation does not establish hardware-specific Bluetooth, HDMI or multi-channel behavior. Shared-Mac live input still requires verified Yomado window **and input-target** isolation; system audio itself is global and was not changed during this work.

API references: [Windows endpoint volume](https://learn.microsoft.com/en-us/windows/win32/api/endpointvolume/nf-endpointvolume-iaudioendpointvolume-setmastervolumelevelscalar), [WirePlumber wpctl](https://pipewire.pages.freedesktop.org/wireplumber/man/wpctl.html). CoreAudio property selectors and native layouts follow the installed macOS SDK headers.
