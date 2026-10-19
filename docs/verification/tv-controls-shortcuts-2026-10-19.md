# TV navigation, text and app shortcuts candidate

Candidate: Android receiver **0.2.1-beta.1 (7)** and iOS **1.0 (21)**. This document describes a development candidate, not a published or hardware-qualified release.

## Behavior

- Native direction/OK/Back/Home and text acknowledgements no longer wait for diagnostic accessibility-tree reads in the foreground TV application. Actual accessibility click/scroll operations still check the target window and node immediately before acting.
- Expired queued directions invalidate dependent confirmations, so a delayed OK cannot activate the old focus after its preceding movement was discarded. Back, Home and explicit app switching remain available; reconnect never replays uncertain actions.
- The right-hand auxiliary pager adds a third page for installed YouTube and Netflix TV apps. Keyboard and dictation button anchors are unchanged. Old receivers do not advertise this page.
- A separate optional top-level `appShortcuts` capability preserves the strict existing `tvControls` schema. Only the fixed `youtube` and `netflix` identifiers are accepted. The receiver checks the current session, awake/unlocked state, enabled accessibility service and a matching exported launcher activity before starting an app. The protocol accepts no arbitrary package, URL or Intent.
- The candidate includes PR #14's validated editor UUID canonicalization. Editor changes and disconnects still invalidate stale text operations.

A successful native-key acknowledgement means the command was handed to Android TV Remote Service, not that its visible effect was independently verified. App launch acceptance similarly does not prove the destination screen loaded.

## Completed checks

- Android: 143 JVM tests passed; lint and main/instrumentation APK builds passed.
- Owned, disposable headless Android TV API 31 emulator: 28 instrumentation tests passed. The emulator was shut down afterward. These tests exercise real Android APIs and private editor fixtures, not household TV applications.
- iOS: 253 Android TV protocol/lifecycle checks; 102 auxiliary gesture/layout checks; 15 native accessibility/contact checks; production device compilation and test-only typechecking passed.
- Actual Swift/Java pinned-TLS interoperability passed, including allowlisted app launches, fresh acknowledgement state, reconnection and no replay.
- All 12 shipped localizations passed key/format validation.
- Independent source review found no blocking issue in the implementation before final commit review. The reviewer independently reran the 253 iOS controller checks.

## Physical-device progress and release gate

| Device | Verified this round | Still required |
| --- | --- | --- |
| Sony XRJ-85X95L, Android 12/API 31 | Authorized ADB connection; same-package candidate upgrade to code 7 succeeded. Existing accessibility authorization retained. | Sofatap IME enable/selection; phone pairing; visible direction/OK/Back/Home and app shortcuts in YouTube/Netflix; browser text; rapid-input/reconnect checks. |
| Xiaomi MiTV-MOEU0 | TV rediscovered on the household network after the user powered it on; Android TV Remote Service reachable. | Current wireless-debugging connection endpoint, same-signed candidate upgrade, full paired phone/application checks. |
| Dedicated iPhone SE | Candidate Build 21 installed successfully. | Control-channel observation became unreliable after launch; no TV-input acceptance claimed. |
| Dedicated iPad | Fresh device-pool READY; candidate Build 21 installed and production landscape UI/device-management page inspected under exclusive leases. | Live TV connection and shortcut/input checks. |

No physical-TV acceptance, TestFlight upload or public receiver release is claimed by these results. Complete and record both household TV/application checks before publishing the requested release. No desktop mouse or keyboard events were sent to the shared Mac.
