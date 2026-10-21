# Isolated iPhone device harness

This **test-only recording receiver** uses Sofatap's production TLS, certificate pinning,
authentication, protocol, acknowledgements and duplicate-message handling. Its input sink
modifies only owned memory and private test files. It never constructs the platform input
injectors, calls a desktop input API, inspects system focus, accesses the clipboard, or
activates a desktop application. It is not packaged with Sofatap.

It deliberately advertises `inputAvailable=true` / `dryRun=false` so the real iPhone can
exercise controls. A standard dry-run receiver disables those controls. Every test window
and result must identify this as **isolated recording only**, and not as successful macOS
input. The unchanged server hello still names the Mac; that is a transport identity,
not evidence that the Mac desktop can be controlled.

## Run

Use a fresh temporary run directory. The helper refuses an existing nonempty directory,
creates it with mode 0700 on Unix, and writes files with mode 0600. The port must be unused
and separate from the installed receiver's port. Do not start or replace the user's
installed receiver for this test.

```sh
.tools/dotnet/dotnet build tests/device-harness/SofaTap.DeviceHarness.csproj -c Release
SOFATAP_HARNESS_RUN="$(mktemp -d /tmp/sofatap-device-harness.XXXXXX)"
.tools/dotnet/dotnet tests/device-harness/bin/Release/net10.0/SofaTap.DeviceHarness.dll \
  --data-dir "$SOFATAP_HARNESS_RUN" --port 54439 --duration-seconds 1800
```

Add `--live-text` to exercise the production `textBegin`, `textSync`, and `textEnd`
protocol against the same owned synthetic field. This explicit flag supplies a
test-only `ILiveTextEditor` implementation; it never creates a platform text editor.
Without the flag, live editing is unavailable and existing draft-send tests keep
their original behavior. `state.json` records `liveText.enabled`, `liveText.reads`,
and `liveText.replacements`. Only an editable synthetic focus permits a live read;
protected fields, changed field identities, text/selection conflicts, invalid
Unicode and recognizable pairing material are rejected.

The Android controller's opt-in JVM compatibility test reads the private pairing
file directly. Set `SOFATAP_CONTROLLER_HARNESS_DIR` to this run directory and run
`:controller:testDebugUnitTest --tests com.chekusu.sofatap.controller.ProductionReceiverCompatibilityTest`
from `android/`. Use `--live-text` for that run to include exact UTF-16 selections,
full-field deletion, Chinese/Japanese/emoji text, duplicate action IDs, stale
revision rejection and a fresh editing session. This validates production wire
compatibility with synthetic memory, not OS text injection or a physical keyboard.

The server stops at the bounded duration (maximum one hour), Ctrl-C, or when its owner
creates the regular file `stop` in the run directory. Shutdown closes the listener,
releases recorded buttons, and removes `pairing.json`. Delete the **owned run directory**
after the device test; the profile still contains its now-unused private key.

`pairing.json` is the only UI handoff file containing live pairing information. It has the
production native-state shape: `pairings: [{host, uri, qrPng}]`. It is local and private;
never print it, attach it to a report, commit it, or include its QR in screenshots. Pair
the test iPhone through its existing manual-link/deep-link flow. A link-based connection
does **not** prove camera scanning. The server listens on the chosen port on all interfaces,
requires its fresh random token and TLS, and uses no browser pairing endpoint.

Use **only synthetic fixture text**. `events.jsonl` and `state.json` contain the test text
to verify exact Unicode delivery. Do not type passwords, private user content or a pairing
link. Recognizable pairing URLs/fields and PEM material are rejected before logging.

## Native canvas state contract

Atomically replaced `state.json` (no token, fingerprint, QR or private key):

```json
{
  "schemaVersion": 1,
  "mode": "isolated-recording-only",
  "osInjection": false,
  "sequence": 0,
  "updatedAt": "2026-10-12T00:00:00Z",
  "width": 800, "height": 500,
  "pointer": {"x": 400, "y": 250},
  "buttons": [],
  "clicks": {"left": 0, "right": 0},
  "scroll": {"x": 0, "y": 0},
  "text": "",
  "selection": {"start": 0, "length": 0},
  "actions": {"move": 0, "click": 0, "button": 0, "scroll": 0, "text": 0, "key": 0},
  "focus": "notfocused", "focusRevision": 0,
  "releases": 0, "lastAction": "start"
}
```

Pointer coordinates are local canvas points clamped to x 0–799 / y 0–499. They never read
or move the system cursor. Buttons show the current held set. `events.jsonl` records
each applied action and release, with a maximum 16 MiB action log. Text is bounded to
160,000 UTF-16 units. The small in-memory editor supports append/selection replacement,
Select All, Backspace/Delete, Enter, Tab, Space, Home and End. Other keys are counted and
recorded, with no invented OS effects. Event counts are stronger evidence of gesture
semantics than visual changes alone. Repeated identical message IDs are deduplicated by
the production server before reaching the recorder.

The read-only native canvas belongs on the existing **non-primary Yomado Agent display**.
It must not activate itself, move the physical pointer, change display layout or fall back
to a physical display. Moving a window alone does not establish OS input isolation.

To simulate focus for automatic-keyboard UI checks, atomically replace `control.json`:

```json
{"focus":"text","revision":1}
```

`focus` is `text`, `protected` or `notfocused`; `revision` is a nonnegative Int32 identifying
a new synthetic field. The harness polls at 200 ms, and the production phone heartbeat
receives this synthetic metadata. Invalid, oversized, non-regular or missing control
files are ignored. This does not test the real macOS Accessibility focus provider.

## Checks and acceptance boundary

```sh
.tools/dotnet/dotnet run --project tests/device-harness/SofaTap.DeviceHarness.csproj -c Release -- --self-test
.tools/dotnet/dotnet run --project tests/device-harness/SofaTap.DeviceHarness.csproj -c Release -- --transport-check
```

Self-tests cover bounded pointer state, held-button release, Unicode editing, focus
fixtures, private filesystem modes and exclusion of pairing material. The transport
check starts the production TLS server with this recording sink, verifies authentication,
real acknowledgements, deduplication, focus metadata and socket-close release, then removes
its private temporary profile. Neither check creates a GUI or sends OS input.

Real iPhone tests can establish actual LAN pairing, phone gesture-to-message behavior,
Unicode draft transport, synthetic focus reactions and disconnect cleanup. They cannot
establish standard receiver OS injection, input consumed by TextEdit or another app,
real desktop focus detection, physical camera scanning via a deep link, recognition of
real speech from injected draft text, or compatibility with untested Typeless workflows.

## Physical phone gesture helper

`phone-gestures.py` adds double-tap, hold-drag and two-finger gestures that the
iPhone Use 0.3.9 MCP surface does not expose. It requires that version's existing
READY channel and reuses its operation lock and current session. It never starts
or recovers a session. Normal taps, app navigation and text entry should continue
through iPhone Use. Read its setup and use skills before operating a device.

Before any gesture, independently verify that the phone's saved host and port
identify this recording receiver. A local `state.json` is not proof of the phone's
selected receiver. Observe the unobstructed phone touchpad and pass its coordinates
in iPhone points, excluding the logo, pairing, keyboard and microphone controls.

```sh
python3 tests/device-harness/phone-gestures.py doubletap \
  --plugin-root /absolute/path/to/iphone-use/0.3.9 \
  --state-dir /absolute/path/to/existing/iphone-use-runtime \
  --harness-state "$SOFATAP_HARNESS_RUN/state.json" \
  --region 90 230 260 510 --start 210 420
```

The example coordinates are not portable to other screens or layouts. Replace
them using a fresh observation. `hold-drag` also needs `--end X Y` and optionally
`--hold-ms 400`; `twofinger-scroll` needs `--end X Y` and optionally
`--finger-gap 36`. Every gesture has one mutation attempt, with no automatic
retry. Confirm the recording events afterward. A successful WDA request alone
does not establish that the phone or receiver interpreted the gesture correctly.
