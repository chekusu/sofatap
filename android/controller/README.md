# Sofatap Android phone controller

This native Android phone/tablet **development alpha** controls the existing Sofatap computer and Android/Google TV receivers over the local network. It is the free manual remote, separate from the [TV receiver](../README.md) installed on a television. It does not require an AI account or paid inference.

The controller targets Android 8.0 / API 26 or later and currently includes English, Simplified Chinese and Japanese. This is source and a development build, not a Google Play release. Physical Android handset input, camera scanning, speech service behavior and receiver compatibility still require acceptance on actual devices; JVM and emulator checks do not establish those results.

## Connect a device

1. Install and open the existing [desktop receiver](../../README.md#get-started) or experimental [Android/Google TV receiver](../README.md). Complete its normal OS permissions.
2. Connect the Android phone and receiver to the same trusted home network. Guest-network isolation can prevent a connection.
3. Open **My devices → Add device**, scan the receiver's QR code, or paste its complete Sofatap pairing link. The code identifies the computer or Android TV automatically. Camera permission is optional when pasting a link.
4. After the authenticated connection succeeds, open the saved device's options to rename it, reconnect, disconnect or forget it. Names are local to this phone. Certificate identity, rather than the IP address or name, determines whether a device already exists.

An Android TV QR code contains a short-lived bootstrap credential. Successful pairing replaces it with a saved credential; failed or interrupted bootstrap attempts require a fresh code. Pairing a new phone can replace the TV receiver's previous phone pairing. Keep pairing links and QR codes private.

The selected saved receiver reconnects while Sofatap is in the foreground, with bounded retry backoff. Backgrounding, switching devices and explicit disconnection close the control connection and discard pending input. Authentication or certificate failures stop automatic retries. A receiver restart with the same valid address and identity can recover; a changed certificate or address can require pairing again. No input is replayed after reconnecting.

## Computer controls

| Gesture or control | Action |
| --- | --- |
| Slide one finger | Move the pointer |
| Tap | Left click |
| Double-tap the left half | Left double-click |
| Double-tap the right half, or tap with two fingers | Right click |
| Hold still for 300 ms, then move | Drag; lifting the finger releases the mouse button |
| Slide two fingers | Natural scrolling |
| Slide in the strip inside the touch surface's right edge | Scrollbar-style scrolling |
| Keyboard / microphone | Compose a local draft, then tap Send |
| Small Backspace / Enter controls | Send Backspace or Enter to the selected device |

Keyboard backspace edits the local draft; the separate Backspace control acts on the receiver. The desktop receiver can announce a new editable field so the phone can open its keyboard, but this alpha does not mirror the field's contents, selection or live edits.

The microphone opens the installed Android speech service. Its availability, network use and data handling depend on that provider; on-device recognition is not guaranteed. A keyboard's own dictation button is another option. Dictation only changes the draft, and text is sent after an explicit Send. Successful acknowledgement clears the sent text. Uncertain delivery keeps the draft and requires checking the target before retrying, avoiding automatic duplicate typing.

## TV controls

The keyboard and microphone retain the computer layout. TV-specific Back and Home buttons appear at the lower right; swipe that small area for directional controls. Swipe on the main touch surface to navigate focus, tap to confirm, or tap with two fingers to go Back. These are remote-control keys, not a claim of global mouse support.

Native directional keys require the TV receiver's Android TV Remote Service connection. Choose **Connect TV remote** in device options and enter the six-character code shown on the TV. This is separate from Sofatap QR pairing. Android-based TVs without that service cannot provide these native keys; Back and Home may still be available through the receiver's accessibility service.

For text, enable and select **Sofatap keyboard** on the TV using its normal system settings, then focus a regular Android editor. Sending, Backspace and the editor action are bound to the current editor identity. Stale editors and protected fields are rejected. Third-party apps can expose no compatible editor. YouTube, Netflix, browsers, individual Sony/Xiaomi models and vendor firmware need separate physical acceptance.

## Privacy and current scope

The controller uses pinned TLS WebSockets. Pairing credentials are encrypted with an Android Keystore key in app-private, backup-excluded storage. The app provides no relay service and does not log entered text or pairing secrets. Drafts are kept per selected device during the activity session and can be restored by Android's activity state; they are not part of the encrypted saved-device file. Removing a saved device also removes its local session draft, but does not revoke another phone's credentials.

This alpha has fixed gestures and explicit text sending. It does not yet include iPhone-style custom gesture profiles, full-field live editing/selection synchronization, lock-screen PIN or biometric unlock, LG webOS, Mac peer/Bluetooth routing, app-launch shortcuts, or paid autonomous voice tasks. It does not self-update. Build and test coverage must be recorded separately from physical phone-to-receiver acceptance.

See the [software verification record](../../docs/verification/android-controller-2026-10-21.md) for executed checks and physical-device gaps.

## Build and checks

Use JDK 17, Android SDK Platform 36 and Build Tools 35.0.0. The repository Gradle wrapper supplies Gradle 8.13. Set `JAVA_HOME` and `ANDROID_HOME` to your own installed paths. From the repository's `android` directory:

```sh
./gradlew --no-daemon :controller:testDebugUnitTest :controller:lintDebug \
  :controller:assembleDebug :controller:assembleDebugAndroidTest
```

The development APK is `controller/build/outputs/apk/debug/controller-debug.apk`, with package `com.chekusu.sofatap`. The television receiver is the separate `com.chekusu.sofatap.tv` package. A store release requires release signing, an app bundle, store materials and its own review.

For an already authorized development phone or disposable emulator:

```sh
adb -s DEVICE_SERIAL install -r controller/build/outputs/apk/debug/controller-debug.apk
adb -s DEVICE_SERIAL shell am start -n com.chekusu.sofatap/com.chekusu.sofatap.controller.MainActivity
adb -s DEVICE_SERIAL install -r controller/build/outputs/apk/androidTest/debug/controller-debug-androidTest.apk
adb -s DEVICE_SERIAL shell am instrument -w com.chekusu.sofatap.test/androidx.test.runner.AndroidJUnitRunner
```

Choose a single dedicated test target before running connected tests. A same-package update requires a compatible signing certificate; do not uninstall or clear user data to hide a signature mismatch. Protocol, storage and transport tests use fakes or loopback endpoints. Actual Mac receiver input tests additionally require verified Yomado virtual-display/input isolation.
