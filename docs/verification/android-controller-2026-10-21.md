# Android phone controller alpha — October 21, 2026

## Scope

`android/controller`, version `0.1.0-alpha.1` (code 1), package `com.chekusu.sofatap`, is an Android phone/tablet **remote controller**. `android/receiver` remains the separate Android/Google TV receiver. No receiver or iPhone source was changed for this alpha.

The implemented scope includes native QR scanning/paste-link pairing, certificate-bound saved devices and rename, foreground reconnection, fixed computer gestures, TV directional navigation/confirm/Back/Home, explicit Unicode text sending, remote Backspace/Enter and installed-system-provider dictation. The Mint Calm touch surface keeps the keyboard and microphone positions consistent between computer and TV modes; TV controls are at the lower right. English, Simplified Chinese and Japanese are included.

## Completed software verification

- JDK 17 / Android SDK 36: debug application and instrumentation APK compilation, 73 unique JVM tests and Android lint passed (0 errors, 19 warnings). The recording-receiver integration is one additional separately executed JVM test.
- Pure JVM tests exercise pairing validation, receiver capabilities, fixed gestures, encrypted-store failure handling, TLS pin and SAN failures, redirects and HTTP busy/auth responses, ACK ordering, bounded queues, no replay after reconnect, stale TV navigation, editor changes, uncertain text delivery and drag release.
- A separate opt-in integration ran the Android controller's production Java transport/action builders against the existing **production receiver TLS/auth/protocol server with its isolated recording input sink**. Exact multilingual/emoji text, grapheme backspace, Select All, Enter, left/right clicks, drag, scrolling, duplicate action IDs, disconnect release and encrypted-store reload/reconnect passed. This test performs no desktop input. The listener was stopped and temporary credentials removed afterward.
- Eight instrumentation tests passed on a disposable Pixel 6 / Android 15 (API 35) ARM64 emulator. These exercise the actual Android Activity, motion-event dispatch, IME, Android Keystore and TLS implementation. They cover native dialogs and paste-link pairing, sequential Unicode sends, an appended speech activity result, Backspace, pointer/tap/drag/two-finger/edge-scroll frames, TV navigation and epoch-bound text, consistent control positions, portrait/landscape with the keyboard, draft recreation, delivery/connection status, and opening the keyboard after a guide dialog closes without reopening it after manual dismissal.
- Native Android parsing tests reject duplicate decoded JSON object keys (including escaped equivalents) before application callbacks, while accepting valid nested JSON. They verify callbacks run on the main Looper.
- Emulator screenshots were inspected, including compact landscape controls with the software keyboard. Test data and receiver names are synthetic. No pairing link, QR credential or private key is included in this report.

The optional production compatibility test is skipped by an ordinary unit-test run unless `SOFATAP_CONTROLLER_HARNESS_DIR` points to a fresh, owned, recording-only harness directory. Its separate successful run is not inferred from a skipped result. CI builds both APKs and runs JVM/lint checks; it does not claim device instrumentation or physical acceptance.

## Fixes established during verification

Malformed ACKs retain a completion outcome; uncertain text is not automatically resent and stays bound to its device. Busy receiver HTTP 409 responses can retry without treating authentication failures as transient. Navigation repeats coalesce and expire instead of moving long after a swipe; a Back/Home/confirm action supersedes unsent directional repeats. Queue pressure cannot strand a drag button. TV controls no longer rebuild on every ACK. Landscape keyboards do not switch the controller into a fullscreen extraction editor, and compact controls remain visible without overlap. Connection failures take precedence over a stale “Sent” notice.

## Acceptance limits

No physical Android handset/tablet, physical camera QR scan, real microphone recognition, or Android-phone-to-Windows/macOS/Linux/TV application input was tested in this task. Speech testing supplied a synthetic recognition activity result; it verifies append/send behavior, not recognition quality. TLS mocks and the recording receiver cannot establish Sony/Xiaomi, YouTube/Netflix/browser or desktop OS input compatibility. No user display, receiver session or normal mouse/keyboard focus was changed.

This is a development-signed alpha, not a Google Play release. Full-field live editing/selection synchronization, custom gesture settings, unlock, LG webOS, Bluetooth/peer routing, TV app-launch shortcuts, self-update and autonomous voice tasks are outside this alpha. Existing receiver permissions and per-platform limits still apply. Real Mac input acceptance requires independently verified Yomado display **and input** isolation.
