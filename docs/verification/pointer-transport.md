# Pointer pacing and optional Apple peer transport

## Shipped behavior

- Desktop touch callbacks send immediately; acknowledgements drain accumulated
  relative movement. Ordinary LAN allows 12 outstanding movement frames, and the
  peer route allows 8. Unsent movement and stalled-flight admission are bounded
  by 120 ms. Reconnection never replays uncertain input.
- Desktop touch gain uses a time-based velocity estimate. Direction and stopping
  are not smoothed into a synthetic movement tail. Drag release preserves the
  final movement ordering. TV gesture semantics remain separate.
- Mac input caches the expensive post-event permission query with bounded
  freshness. Console session and Accessibility trust checks remain synchronous.
- Automatic routing prefers a matching Bonjour service scoped to AWDL, with
  bounded discovery and ordinary LAN fallback. Retryable peer failure selects LAN
  for the next reconnect. TLS still authenticates the original hostname, full
  certificate pin and pairing token through the opaque bridge.
- My Devices offers Auto and Regular Wi-Fi only while a matching AWDL service is
  visible. The preference persists. Settings discovery remains independent of the
  selected transport and stops when settings closes or the app is inactive.
  Advertised availability does not replace connection authentication.
- Numeric pointer diagnostics are DEBUG-only, bounded histograms and counters;
  they do not include coordinates, typed text or pairing credentials. Their local
  JSON output is not a distributable test fixture.

## Repeatable checks

Run from the repository root on macOS with Xcode command-line tools and the
project .NET SDK available. The TLS integration script uses the Release receiver
assembly and creates a temporary dry-run profile.

```sh
bash ios/scripts/test-pointer-motion.sh
bash ios/scripts/test-drag-release.sh
bash ios/scripts/test-pairing-attempt.sh
bash ios/scripts/test-peer-discovery.sh
bash scripts/macos/test-peer-lifecycle.sh
bash ios/scripts/test-explicit-text.sh
bash ios/scripts/test-live-text.sh
.tools/dotnet/dotnet build host/SofaTap.Host.csproj -c Release
.tools/dotnet/dotnet run --project tests/host/SofaTap.Host.Tests.csproj -c Release
python3 tests/peer-tls-bridge.py
python3 ios/scripts/check-localizations.py
git diff --check
```

The initial targeted review passed 122 connection/lifecycle checks, 15 pointer
motion checks, 93 touch gesture checks, 51 drag checks, 61 explicit-text checks
and 63 live-text checks. Later review results are recorded below. Real Bonjour tests exercise matching, interface scoping,
service removal, timeout and cancellation. The TLS bridge tests cover a valid
pinned connection, invalid pin/hostname/token, stopped endpoints and cleanup.
All 12 localization catalogs passed. The earlier complete host and TLS/WebSocket
regression runs passed 421 and 69 checks respectively. Controller fixtures and
recording sinks do not inject real desktop input.

## Physical-device observations and limits

Two physical-phone ABBA experiments compared LAN movement windows 8/12/12/8.
For the measured environment, send-interval P99 was approximately 38–46 ms with
8 slots versus 9–10 ms with 12. These were synthetic pacing experiments against
an isolated dry-run receiver, not actual touch gestures. They support reducing
sender pauses, not eliminating network jitter. The subsequent manual LAN test
was reported to feel somewhat better; residual stutter remained.

Separate encrypted peer/LAN comparisons and actual receiver sockets confirmed
AWDL transport on the tested iPhone/Mac. The final development build launched and
connected with the receiver reporting desktop-ready. This does not establish
compatibility with every Apple device or a universally optimal network setting.
Physical radio-interruption recovery and the final settings UI transitions were
not manually exercised; their policy/lifecycle behavior has automated coverage.
No automated cursor/keyboard acceptance was performed on the shared desktop
without verified input isolation.

Raw device captures, experimental apps, local profiles, signing material and
chronological development notes remain local and are excluded from the PR.

## Review follow-up

The first busy-refusal fix was incomplete: its 58-check recording fixture passed
raw errors directly to the completion callback and bypassed production ACK
normalization. The real dispatcher removed the colon suffix and replaced
`input_busy` with generic display text, so the recovery branch never matched.

The follow-up regression failed before the correction. It now records serialized
outbound frames, creates real pending commands and feeds ACKs through the
production dispatcher. The dispatcher preserves an allowlisted machine code,
keeps display text bounded and matches `input_busy` exactly. A non-drag busy
refusal clears unsent motion and keeps the session for fresh input. Held/releasing
drags, partial delivery and uncertain results still disconnect; no uncertain
frame is replayed.

The corrected suite passes 66 checks, including busy codes with and without a
suffix, queued-motion discard, fresh-gesture recovery, unknown/partial failures,
timeouts and held/releasing drags. Connection/lifecycle (122), explicit text (61),
live text (63), TLS/WebSocket dry-run integration (69), all six pinned-TLS bridge
scenarios and 12-locale validation also passed. The controller regression covers
production ACK dispatch but substitutes network I/O; it is not a physical-device
end-to-end test. TLS integration alone does not verify physical mouse ownership.

Development builds iOS 41 and macOS 37 were installed and launched; the receiver
reported desktop-ready and sockets confirmed AWDL transport. The user subsequently
reported manual acceptance on the device-direct route:
phone movement did not move the pointer while the physical left mouse button
was held, and fresh phone movement worked after release. This confirms observed
refusal/recovery; uninterrupted connection was not explicitly reported. The user
also confirmed that phone dragging moves a window, releasing the
gesture stops the drag, and subsequent ordinary movement moves only the pointer.
These are user-reported observations, not automated input verification. The local
receipt records source hashes, checks and these limitations. No automated desktop
input is permitted until virtual-display input isolation has been verified.
For manual acceptance, the user holds a physical mouse button while moving on
the phone, releases it and verifies that a fresh phone gesture works without
reconnecting; a separate phone drag must stop when released. Record the observed
transport and each outcome, without treating connection readiness as acceptance.

The helper publishes validated peer port/certificate metadata independently of
LAN QR addresses. Native-controller tests use a real relay to verify survival of
empty pairing lists, port/certificate rotation, shutdown and addressless startup.
The host suite passes 424 checks. Older helper states without peer metadata still
decode for LAN use, but cannot advertise the new peer transport.

The TLS bridge check creates its output directory and accepts SOFATAP_DOTNET for
CI. It passed with no existing artifacts directory using a temporary source
fixture and the built Release receiver. Explicit capture lists retain the
warnings-as-errors compile gate. Local validation used Swift 6.2; Swift 6.4 was
not installed locally. Both peer lifecycle and TLS bridge checks are wired into
CI. No physical radio interruption or desktop input was induced by these tests.
