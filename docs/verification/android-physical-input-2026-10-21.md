# Android input compatibility follow-up — October 21, 2026

This is an in-progress acceptance record, not a release or a claim of complete phone-to-receiver compatibility.

## Confirmed handset finding

On an OPPO Find N3 (PHN110, Android 16/API 36), the public controller's camera permission and live rear-camera preview work. No receiver QR has yet been decoded in this acceptance run. Having a Google application installed does not establish an available Android speech recognition service: the system's standard recognition service and activity queries returned no enabled matches.

The controller now checks recognition availability before asking for microphone permission. It prefers the configured standard service, then an available on-device service on API 31 or later. If neither exists, the explicit microphone action opens the current keyboard and explains how to use that keyboard's own microphone. This does not enable a provider, change the default keyboard, or start keyboard dictation automatically. Keyboard permissions and audio handling belong to that keyboard.

The fallback must retain the current draft and selection. For a live computer field, its explicit keyboard request must also survive asynchronous text import when the receiver cannot classify the focused field. Changing device, disconnecting, or leaving the foreground must cancel stale requests.

## Physical acceptance boundaries

| Check | Status in this run |
| --- | --- |
| Find N3 rear-camera preview | Confirmed |
| Optical QR pairing to the production Windows receiver | Pending |
| Actual acoustic recognition through the installed keyboard | Pending |
| Find N3 to Windows real mouse, scroll and text input | Pending |
| Find N3 to Sony TV navigation and ordinary-field text | Pending |
| Xiaomi TV | Deferred; Sony results must not be generalized to Xiaomi |

Windows acceptance uses an isolated test application in the receiver's unlocked RDP session. The Mac's Windows App is a read-only observer on a task-owned, non-primary Yomado display; the physical display layout stays unchanged. Phone input must go directly to the selected Windows receiver, with fresh foreground and session checks before live actions.

The Sony receiver and Sofatap input method are installed, enabled and selected. Those setup facts do not prove directional Remote Service pairing, third-party application input, or Android phone control. Native direction navigation and pointer control remain distinct capabilities.

Software, emulator and protocol-fixture tests are recorded separately from the pending optical, acoustic and operating-system input checks above. Do not replace these pending checks with injected speech transcripts or a pasted pairing URI.

## Software verification

- Controller JVM suite: 121 discovered, 120 passed, one existing opt-in test skipped, zero failures or errors.
- Debug controller and native-test APK compilation passed. Android lint: zero errors, 29 warnings.
- Native emulator suite: **16 passed** (12 controller, two gesture-settings, two pinned-TLS checks). This includes missing-provider draft/selection preservation, delayed live import with unknown focus, and cancellation after backgrounding or device changes.
- An initial emulator run was blocked by a System UI not-responding dialog. Its ten failures were retained; after closing that dialog through the emulator UI, the complete suite passed without changing application code, test assertions or emulator settings.
- Independent source review identified and then verified the asynchronous explicit-keyboard request fix.

The tests above use controlled fixtures and do not replace physical camera, acoustic speech or receiver input acceptance. This change remains a candidate: no new Android APK version has been released as part of this follow-up. The public website now exposes the existing Android controller 0.1.0-beta.1 download separately from the TV receiver.
