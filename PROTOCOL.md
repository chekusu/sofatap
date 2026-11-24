# Sofatap protocol v1

Native iPhone controller and Windows/macOS/Linux receivers, local network, TLS with certificate pinning.

The `v0.1.1-alpha` release adopts the Sofatap brand and the `sofatap://` pairing scheme. The wire protocol remains version 1. Its new iOS bundle ID (`com.chekusu.sofatap`) and Windows profile (`%LOCALAPPDATA%\SofaTap`) do not automatically migrate previous pairing credentials; both ends must be paired again.

## Pairing

The desktop receiver shows a QR code containing:

`sofatap://pair?host=192.0.2.17&port=53319&token=<base64url-32-random-bytes>&fingerprint=<lowercase-sha256-hex-of-DER-leaf-certificate>&platform=windows&name=Living%20room%20PC`

No cloud service. Client stores the pairing in Keychain. Validate all QR fields: IP/hostname only (no URL path/userinfo), port 1..65535, token 32+ characters, fingerprint exactly 64 hex characters. IPv4 is the initial advertised host format.

The unified scanner accepts exactly the four required fields `host`, `port`, `token`, `fingerprint`, plus optional `platform` and `name` in any order. Reject duplicate or unknown fields. `sofatap://pair` allows `windows`, `macos` or `linux`; `sofatap://tv` is the Android/Google TV receiver namespace and only allows `androidtv`. A platform that conflicts with its namespace is invalid. Metadata does not select another host, confer trust, alter the TLS pin or start an automation task.

`name` is a display hint: reject Unicode control/format characters (general categories Cc and Cf) before trimming outer Unicode whitespace. The normalized name must be nonempty, at most 80 Unicode scalar values and at most 256 UTF-8 bytes. Count scalars, not grapheme clusters or UTF-16 code units. Emit names using UTF-8 percent encoding; a literal `+` in a URI query remains `+`, not a space. Receivers trim safe OS names before emitting them and use a static platform name when the OS name is invalid; they do not truncate an unsafe name. Desktop copy-link validators apply the same field, metadata and endpoint checks. The selected native pairing endpoint must match the link's host.

The new scanner remains compatible with older four-field QR codes, which simply lack a device label/platform hint. **Compatibility is one-way:** iOS 1.0 build 14 and earlier require exactly four fields and cannot scan the new metadata QR codes. Upgrade the iPhone app before using an updated receiver. The transport protocol version remains 1; the metadata extension changes QR parsing, not authentication or input capabilities.

Android receivers emit `sofatap://tv?host=<private-ipv4>&port=53319&token=<bootstrap-token>&fingerprint=<sha256>&platform=androidtv&name=<percent-encoded-device-name>`. Their existing private IPv4, bootstrap expiry/rotation, TLS pin and capability rules remain unchanged. LG webOS pairing uses its own adapter and is not represented by this Android QR namespace.

## Connection

`wss://<host>:<port>/control`, header `Authorization: Bearer <token>`.

The iPhone validates the server leaf certificate against the scanned SHA256 fingerprint. Do not install a root CA, disable trust globally, or accept other certificates. Server denies browser Origins and unauthenticated requests. One controlling connection at a time. Text is never logged. A transport failure or reconnect must not replay input automatically. Each connection has a bounded cache of action IDs and their payload digest/ACK. An identical duplicate returns its original ACK without repeating input; a conflicting reused ID fails. Exhausting the cache closes the connection rather than evicting IDs that could be replayed.

The receiver preserves its pairing profile across restarts. Adding a network adapter does not rotate credentials while the prior certified addresses are still present; pure removal and a temporarily offline restart also retain the profile. Advertised QR addresses remain restricted to the certificate SAN. Replacing a certified address with an uncertified one still renews the certificate, including when a VPN address remains stable. First going online with a loopback-only certificate and certificate renewal also require a new certificate/token and explicit pairing. Device names and IP addresses are not trusted identity keys and cannot silently merge different saved certificate identities.

The desktop phone controller retries transient connection failures only for its explicitly selected device while active. Retry delays grow from 1 to 30 seconds; an authenticated hello resets the delay. HTTP 409 can be temporary while a previous controller connection is being released. Authentication, certificate and protocol failures stop automatic retries. Manual disconnect, cancellation, backgrounding and target changes invalidate queued retries. Neither an old retry nor a callback from an earlier connection may affect the new target or replay input.

## Frames

Each client frame and server response is one UTF-8 JSON object (max 64 KiB) with a unique string `id` (UUID) and `type`. Server replies `{"type":"ack","id":"...","ok":true}` or `{"type":"ack","id":"...","ok":false,"error":"..."}`. On connection: `{"type":"hello","version":1,"name":"Computer name","platform":"macos","dryRun":false,"inputAvailable":true,"inputStatus":"ready"}`.

The additive v1 fields `platform` (`windows`, `macos`, `linux`, `unknown`), `dryRun` and `inputStatus` also distinguish `dry_run`, `accessibility_required` and `desktop_unavailable`. `inputAvailable` is false for every unavailable status. Older receivers omit the new fields; false availability must not be interpreted as proof of dry-run. Unknown statuses disable controls. A successful `ping` ACK includes current `inputAvailable`, `inputStatus` and `dryRun`, so authorization and lock changes are reflected without reconnecting. Legacy clients can ignore these additive fields.


The experimental account-password `hello.unlock` capability is retired and is no longer emitted, including on ready Windows desktops with legacy enrollment files. Clients must not use cached password capabilities or treat them as Windows Hello PIN credentials. Native lock-screen pointer/manual PIN and Face ID-authorized PIN entry need a separately verified protocol; no PIN capability is currently advertised. See [current validation scope](docs/FACE-ID-UNLOCK.md) and the [historical password design](docs/archive/PASSWORD-LOGIN-PILOT.md).

Development version 0.5.0 adds `textFocus: {"state":"editable","revision":1}` to hello and ping ACKs. The state is `editable`, `other`, `protected` or `unknown`; revision is a nonnegative connection-local integer, changing when the target/state changes. Native element identity and field contents are never serialized in these focus hints; explicit live-editing responses can contain current field text and selection as described below. Locked, unavailable and dry-run receivers return `unknown`; dry-run never creates the native focus probe. Missing, malformed or unknown metadata disables automatic keyboard behavior while preserving manual keyboard access. Clients poll at most every 750 ms when this metadata is advertised, with only one outstanding ping; legacy receivers retain the five-second heartbeat. These hints are advisory, not a promise that the application will accept input. See [platform focus detection](docs/TEXT-FOCUS.md).

Injection failure errors start with `input_failed:` when no event was submitted to the system and `input_partial:` when a prefix may have been submitted. The client must treat `input_partial:` as uncertain delivery, preserve the draft, and require an explicit review before enabling resend. Unknown text failure semantics are also treated conservatively as uncertain.

- `{"id":"...","type":"move","dx":3.5,"dy":-2}`: relative mouse movement, each finite number limited to +-500. Receiver accumulates fractional movement.
- `{"id":"...","type":"click","button":"left"}`: left/right click down+up.
- `{"id":"...","type":"button","button":"left","down":true}`: hold/release for drag. Release all held buttons on disconnect, timeout, or shutdown.
- `{"id":"...","type":"scroll","dx":0,"dy":-120}`: relative scroll units; Windows maps 120 to one wheel notch, while macOS maps 120 to a 120-point pixel-scroll request through Quartz. Both limited to +-1200.
- `{"id":"...","type":"key","key":"enter","modifiers":[]}`: allowed keys enter, tab, escape, backspace, delete, up, down, left, right, home, end, pageup, pagedown, space, a, c, v, x, z; modifiers ctrl, alt, shift, win. On macOS these mean Control, Option, Shift and Command; iOS selects `win` for Mac semantic shortcuts such as Select All, and `ctrl` for Windows. Press+release with best-effort release of owned keys on error. A lock, logout or revoked Mac permission can prevent release delivery; no input is replayed into a later session. No arbitrary executable/script commands.
- `{"id":"...","type":"text","text":"你好 Windows 👋"}`: commit an entire Unicode string, <= 16,000 UTF-16 code units. Type ordinary text into the foreground field via Windows SendInput KEYEVENTF_UNICODE (UTF-16 surrogate pairs preserved). Each embedded CRLF, lone LF or lone CR becomes one VK_RETURN down/up pair, because Windows editors can ignore Unicode CR packets. No extra Enter or submit action is appended. Embedded line breaks therefore follow the target application's Enter behavior: they insert a paragraph in multiline editors, but may submit a form or send a message in other fields; test the intended target. Windows rejects the entire multiline action before injection with `input_busy:` while Enter, Ctrl, Alt, Shift or either Windows key is held. On macOS use Quartz Unicode keyboard events, preserve surrogate pairs, and normalize line breaks to CR. A successful ACK means the backend submitted the event sequence to the system; macOS CGEventPost has no delivery result. It does not prove a specific app received, saved or submitted text. This is the review-and-send fallback: its iOS draft stays local until explicitly sent. It does not replace existing computer text or mirror phone deletions. Clients must keep unsent fallback text on failure, avoid duplicate sends, and preserve composition/dictation state.
- `{"id":"...","type":"ping"}`: keepalive and optional focus-state refresh. Client sends every 750 ms with focus metadata, otherwise every 5 seconds while foreground; server idle limit 20 seconds. Becoming inactive stops touch input and releases held buttons; a temporary native permission sheet may keep the connection. Backgrounding closes the connection and stops live editing; a fallback draft remains saved, while imported live text is not saved to draft preferences. Foregrounding can reconnect without replay.

Receiver rejects unknown fields/types, non-finite/out-of-range numbers, malformed JSON, unsupported keys/buttons. Credentials must never appear in logs, build artifacts, source control, or test receipts. Sensitive action ACKs have a bounded timeout; ambiguous text delivery is shown as uncertain, not retried automatically.

## Live text editing extension

Development source 0.7.0 advertises the additive `hello.liveText: {"version":1}` capability on normal Windows/Mac receivers with a live backend. Dry-run and Linux omit it. This advertises backend availability, not support for every focused field. Older clients can ignore it; older receivers and unsupported fields retain the `text` fallback.

- `{"id":"<uuid>","type":"textBegin"}` opens a session on the current supported field. It returns `{"type":"ack","id":"<uuid>","ok":true,"liveText":{"session":"<session-uuid>","revision":0,"text":"Existing text","selectionStart":0,"selectionLength":0}}`. A new begin replaces the connection's previous session. The native target identity is never transmitted.
- `{"id":"<uuid>","type":"textSync","session":"<session-uuid>","revision":1,"text":"Edited text","selectionStart":11,"selectionLength":0}` requests the next complete text/selection state based on the previous acknowledged snapshot. Revisions increase exactly by one; only one update should be in flight, with later phone changes coalesced. Success returns the same `liveText` shape with exact native readback and the accepted revision. The complete wire value does not mean the backend rewrites the complete field: native backends replace only the changed span.
- `{"id":"<uuid>","type":"textEnd","session":"<session-uuid>"}` ends that session. Ending an already-replaced session does not close a newer one. Clicks, keys, fallback `text` and mouse-button presses also invalidate the active live session; pointer movement alone does not.

Text and selection indices use UTF-16 code units, with a 16,000-unit maximum and no selection boundary inside a surrogate pair. NUL, invalid Unicode, negative/overflowing ranges and out-of-order revisions are rejected. Native Windows newlines are mapped to LF and selection offsets are converted accordingly; a single-line Windows control rejects a new line. The live backend uses field replacement, not simulated Return presses. IME marked text stays local until committed; speech partial results and later revisions can update the live field immediately without Send.

The native receiver compares focused target, text and selection against the last acknowledged snapshot before modifying anything, and verifies the resulting native value and selection. `live_text_unsupported:` means the field/backend lacks precise editing support; the phone can offer review-and-send. `live_text_conflict:` and `live_text_changed:` stop the session after target/content/selection changes. `live_text_uncertain:` means a mutation may have happened without confirmed readback. Conflicting and uncertain edits must not be retried or rolled back automatically; retain the phone's in-memory result for inspection and deliberately reopen the editor. A successful live ACK establishes text/selection readback, not that the target application saved or submitted it.

Windows currently uses normal native Unicode Edit/RichEdit controls, requiring an unlocked Default desktop, the receiver's session, a non-elevated target and no password/read-only state. It does not provide browser or arbitrary custom-widget editing. Mac requires readable AX text and writable `AXSelectedText`/`AXSelectedTextRange`, rejects secure/unsupported fields, and makes bounded AX calls without global input or clipboard operations. Linux currently has no live-text backend. Per-application and real-device acceptance are separate from these implemented capabilities.

Unlike background focus metadata, an explicit live session reads and transfers the complete current field text and selection to the paired phone. The phone keeps imported live values in memory rather than saved draft preferences. The receiver's duplicate-suppression cache retains text-bearing ACKs in connection memory, bounded by action count and accumulated text units; it is not persisted or logged. A repeated identical ID returns its cached ACK without reading or modifying a new field. A conflicting ID fails. Disconnect discards the connection session/cache, and uncertain work is never replayed on reconnect.

Native responses use compact Unicode JSON encoding over pinned TLS, never HTML. The actual escaped text size is checked before accepting a live begin/sync, with 1,024 bytes reserved for its envelope. All outgoing frames are additionally checked against 64 KiB. Thus a CJK/emoji field cannot be modified successfully and then lose its ACK solely because default JSON escaping expanded the response beyond the client limit.

## Device link for receiver extensions

Paid Mac builds can ship helpers that need the phone's account link. After pairing, the phone may send `{"id":"<uuid>","type":"deviceLink","token":"sbl_<64 lowercase hex>","api":"https://…","expiresAt":"…"}` and, when it signs out or unlinks, `{"id":"<uuid>","type":"deviceUnlink"}`. Both are acknowledged like other actions and inject no input. The API must be an absolute https URL of at most 256 characters, and `expiresAt` a non-empty string of at most 64 characters. The receiver keeps the latest token in memory only; on macOS it adds `deviceLink: {"token","api","expiresAt"}` to its private native state line, and the launcher writes it to the stdin of bundled helpers whose manifest sets `wantsLink` (see desktop/macos/README.md). Other platforms accept the actions and do nothing with them. A receiver restart forgets the token; the phone sends it again on its next connection.

## Verification boundary

Dry-run is allowed on Windows, macOS and Linux for protocol/TLS tests and must report inputAvailable=false. Linux real input uses X11 XTest/libxdo or an explicitly authorized Wayland RemoteDesktop portal. Actual pointer/text injection requires physical interactive desktop tests on each supported OS. Mac requires an active, unlocked console session and Accessibility/post-event authorization; reading availability must not prompt. The native window provides an explicit permission action through inherited process pipes. The receiver has no HTTP/HTML pairing dashboard or local HTTP action endpoints. A bounded JSON line protocol accepts only refresh, requestAccess and quit; EOF stops the receiver and releases owned input. Pairing QR PNGs and URIs are provided only to this local parent process. The network endpoint still accepts only authenticated WSS control messages. macOS secure fields and applications rejecting synthetic events are outside the verified contract. iOS simulator tests do not establish Typeless, camera, physical gyroscope, or real iPhone LAN behavior.

## Native desktop window bridge

The signed desktop launcher starts the bundled receiver with `--native-ui` and redirects both standard streams. The backend refuses this mode on an interactive terminal. Standard output is reserved for newline-delimited state objects: `type`, `name`, `platform`, `inputStatus`, `dryRun`, `connected`, and `pairings` (each `host`, `uri`, base64 `qrPng`), plus `peer` and, on macOS while a phone has linked, `deviceLink`. Do not log or persist state frames: they contain pairing credentials. Errors use a separate stream and frontends display fixed messages. Status refreshes every two seconds.

The Mint Calm native windows offer an explicit Copy pairing link action. Frontends retain the selected validated URI in memory for that action; they never automatically copy it or display its secret text. Windows and Linux accept older QR-only snapshots with Copy disabled. Missing, malformed or oversized optional URIs likewise disable Copy. This UI action is separate from remote text injection, which keeps its existing clipboard behavior. Appearance fixtures must use synthetic, non-pairing QR content and no real credentials.

The parent may send exactly one field: `{"type":"refresh"}`, `{"type":"requestAccess"}` or `{"type":"quit"}`. Commands are bounded to 4 KiB; unknown/duplicate fields are rejected. macOS and Wayland permission requests are explicit local user actions and disabled in dry-run. Pipe EOF and Quit cancel connected WebSockets before stopping the host. Native frontends must terminate their own child on unrecoverable framing errors, never an arbitrary process. Linux's GTK3 window launches in real-input mode by default; --dry-run is an explicit preview option.

## Linux receiver metadata and limits

The Linux receiver uses protocol version 1 without changing action schemas. Its
`inputStatus` is `ready`, `permission_required`, `permission_pending`,
`permission_denied`, `desktop_unavailable`, `unsupported_session`,
`dependency_missing` or `input_unavailable`; explicit dry-run remains `dry_run`.
Only `ready` enables input. Permission requests are local native-window actions,
never remote WebSocket commands. The existing iPhone client fails closed for
unknown status codes and can use a ready Linux receiver.

Linux text is limited to 2048 Unicode scalar values per action (and the common
16000 UTF-16-unit/64 KiB frame bounds). Overlong input is rejected before sending
its first character. X11 also rejects a selection before input when temporary key-slot capacity or its preflight time budget is exceeded. A desktop method failure or deadline after attempting input
is `input_partial`/unknown; no client should retry it automatically. An ACK means
input was submitted, not that a target app received or saved it. Linux text uses
X11 key events or Wayland Unicode keysyms, not clipboard replacement. Wayland
requires a compositor portal implementing the requested methods and Unicode
keysyms; mock portal checks do not establish compositor compatibility.
