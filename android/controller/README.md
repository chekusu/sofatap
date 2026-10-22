# Sofatap Android phone controller

The native Android phone/tablet controller **0.1.0-beta.1** controls existing Sofatap computer and Android/Google TV receivers over your home network. It is the free manual remote, separate from the [TV receiver](../README.md) installed on a television. It does not require an AI account or paid inference.

Android 8.0 / API 26 or later is required. English, Simplified Chinese and Japanese are included. This is a direct-APK pre-release, not a Google Play release, and it has no self-updater. Physical phone, camera, microphone and application compatibility are qualified separately; a build or emulator result does not establish those outcomes.

Direct APK: [0.1.0-beta.1 pre-release](https://github.com/chekusu/sofatap/releases/tag/android-controller-v0.1.0-beta.1) · [Sofatap-Android-0.1.0-beta.1.apk](https://github.com/chekusu/sofatap/releases/download/android-controller-v0.1.0-beta.1/Sofatap-Android-0.1.0-beta.1.apk). Install the APK using Android’s normal installation confirmation; allow installation from your browser or file manager if Android requests it. For updates, download the newer APK from the same repository and install it over the existing app without clearing its data.

## Connect a device

1. Install and open the existing [desktop receiver](../../README.md#get-started) or experimental [Android/Google TV receiver](../README.md). Complete its normal OS permissions.
2. Connect the Android phone and receiver to the same trusted home network. Guest-network isolation can prevent a connection.
3. Open **My devices → Add device**, scan the receiver's QR code, or paste its complete Sofatap pairing link. The code identifies the computer or Android TV automatically. Camera permission is optional when pasting a link.
4. After the authenticated connection succeeds, open the saved device's options to rename it, reconnect, disconnect or forget it. Names are local to this phone. Certificate identity, rather than the IP address or name, determines whether a device already exists.

An Android TV QR code contains a short-lived bootstrap credential. Successful pairing replaces it with a saved credential; failed or interrupted bootstrap attempts require a fresh code. Pairing a new phone can replace the TV receiver's previous phone pairing. Keep pairing links and QR codes private.

The selected saved receiver reconnects while Sofatap is in the foreground, with bounded retry backoff. Backgrounding, switching devices and explicit disconnection close the control connection and discard pending input. Authentication or certificate failures stop automatic retries. A receiver restart with the same valid address and identity can recover; a changed certificate or address can require pairing again. No input is replayed after reconnecting.

## Computer controls and gesture settings

The default **Sofatap** preset behaves as follows. Custom presets can change these mappings.

| Gesture or control | Default action |
| --- | --- |
| Slide one finger | Move the pointer |
| Tap | Left click |
| Double-tap the left half | Double left click |
| Double-tap the right half | Double right click |
| Hold still for 300 ms, then move | Drag; lifting the finger releases the mouse button |
| Double-tap and hold, then move | Drag |
| Slide two fingers | Natural scrolling |
| Slide in the strip inside the touch surface's right edge | Scrollbar-style scrolling |
| Keyboard / microphone | Live editing on supported computer fields; draft-and-send elsewhere |
| Small Backspace / Enter controls | Delete or confirm on the selected device |

Open **Gestures** from the guide to choose **Sofatap**, **Trackpad**, or **Press shortcuts**, or assign individual actions. The nine configurable gestures are one-finger tap, left/right-half double tap, two/three-finger tap, long press, double-tap-and-hold, and one/two-finger movement. Computer and TV profiles are saved separately. Long-press delay, double-tap interval and natural scrolling are adjustable; the right-edge scroll strip keeps its scrollbar direction. The practice pad is local and sends no device commands. Actions unavailable on the current receiver cannot be selected, while existing saved choices are retained.

### Live editing and fallback drafts

When a computer receiver and its focused field support live editing, opening the keyboard or microphone reads that field's text and selection. Committed keyboard input, selections, deletion and available dictation results then synchronize without tapping Send; the send arrow becomes a checkmark. Uncommitted IME composition stays local until committed. Receiver focus notices can open the keyboard for a new editable field. Password, read-only and unsupported fields cannot enter live editing.

Field support is narrower than ordinary text sending: Windows currently supports native Edit/RichEdit fields, macOS requires writable Accessibility text and selection, and Linux uses draft-and-send. See [text focus and platform limits](../../docs/TEXT-FOCUS.md). Changes on the computer, loss of focus or a connection failure pause live editing. Check the target before choosing **Read field again**, which replaces the phone editor with the current computer field. Uncertain edits are never automatically replayed.

When live editing is unavailable, compose a local draft and tap the arrow to send. Keyboard backspace edits that draft; the separate Backspace control acts on the receiver. Successful acknowledgement clears the sent text. Uncertain delivery retains the draft and requires checking the target before retrying.

### Dictation

**Published APK:** Tap the microphone to start foreground dictation and tap again to finish, or assign **Start or stop dictation** to a computer gesture. The released controller uses the standard Android speech recognizer, requires Sofatap microphone permission and requests partial results. If that recognizer is unavailable, it shows an unavailable-service message. You can separately use your keyboard’s own dictation button. Results update the editor as the recognizer supplies them; they synchronize to a supported live computer field, while fallback drafts and TV text still require Send. Recognition availability and partial-result frequency depend on the recognizer. The standard provider may process audio online. Leaving the app cancels Sofatap’s own recording session.

**Unreleased source candidate — not in the linked APK:** If the standard recognizer is unavailable, Android 12 / API 31 and later try supported on-device recognition, which also requires Sofatap microphone permission. If neither recognizer is available, tapping Sofatap’s microphone opens the current keyboard and prompts you to tap that keyboard’s own microphone, if it provides one. Sofatap cannot automatically start keyboard dictation. This keyboard fallback does not request Sofatap microphone permission; recording permissions, recognition availability and audio handling are controlled by the keyboard. Its committed text follows the same live-editing or explicit-Send rules as ordinary keyboard input.

## TV controls

The keyboard and microphone retain the computer layout. TV-specific Back and Home buttons appear at the lower right; swipe that small area for directional controls. In **directional remote** mode, swipe on the main surface to navigate focus, tap to confirm, or tap with two fingers to go Back. These fixed navigation gestures are separate from TV **pointer** mode, which uses the TV gesture profile and requires actual receiver/app pointer support. Remote-control keys do not establish global mouse support.

Native directional keys require the TV receiver's Android TV Remote Service connection. Choose **Connect TV remote** in device options and enter the six-character code shown on the TV. This is separate from Sofatap QR pairing. Android-based TVs without that service cannot provide these native keys; Back and Home may still be available through the receiver's accessibility service.

For text, enable and select **Sofatap keyboard** on the TV using its normal system settings, then focus a regular Android editor. Type or dictate on the phone and explicitly tap Send. Sending, Backspace and the editor action are bound to the current editor identity. Stale editors and protected fields are rejected. This version does not mirror a TV field's full text or selection. Third-party apps can expose no compatible editor. YouTube, Netflix, browsers, individual Sony/Xiaomi models and vendor firmware need separate physical acceptance.

## Privacy and current scope

The controller uses pinned TLS WebSockets. Pairing credentials are encrypted with an Android Keystore key in app-private, backup-excluded storage. The app provides no relay service and does not log entered text or pairing secrets. Live editing transfers the supported field's text and selection to the paired phone. Local drafts are kept per selected device during the activity session and can be restored by Android's activity state; they are not part of the encrypted saved-device file. Removing a saved device also removes its local session draft, but does not revoke another phone's credentials. Gesture preferences remain local to the phone.

Lock-screen PIN or biometric unlock, LG webOS, Mac peer/Bluetooth routing, TV app-launch shortcuts, self-update and paid autonomous voice tasks are not included. Basic dictation is free manual text input, not an agent that operates the device for you. Build and test coverage must be recorded separately from physical phone-to-receiver acceptance.

See the [verification record](../../docs/verification/android-controller-2026-10-21.md) for the exact versions and checks performed; historical alpha results do not qualify subsequent beta changes.

## Build and checks

Use JDK 17, Android SDK Platform 36 and Build Tools 35.0.0. The repository Gradle wrapper supplies Gradle 8.13. Set `JAVA_HOME` and `ANDROID_HOME` to your own installed paths. From the repository's `android` directory:

```sh
./gradlew --no-daemon :controller:testDebugUnitTest :controller:lintDebug \
  :controller:assembleDebug :controller:assembleDebugAndroidTest
```

The development APK is `controller/build/outputs/apk/debug/controller-debug.apk`, with package **`com.chekusu.sofatap.dev`** and version suffix `-dev`. The public release package is **`com.chekusu.sofatap`**, version `0.1.0-beta.1` (code 2); it requires release signing. Debug and public installations coexist with separate device data. The television receiver remains the separate `com.chekusu.sofatap.tv` package. Google Play distribution would require an app bundle, store materials and its own review.

For an already authorized development phone or disposable emulator:

```sh
adb -s DEVICE_SERIAL install -r controller/build/outputs/apk/debug/controller-debug.apk
adb -s DEVICE_SERIAL shell am start -n com.chekusu.sofatap.dev/com.chekusu.sofatap.controller.MainActivity
adb -s DEVICE_SERIAL install -r controller/build/outputs/apk/androidTest/debug/controller-debug-androidTest.apk
adb -s DEVICE_SERIAL shell am instrument -w com.chekusu.sofatap.dev.test/androidx.test.runner.AndroidJUnitRunner
```

Choose a single dedicated test target before running connected tests. A same-package update requires a compatible signing certificate; do not uninstall or clear user data to hide a signature mismatch. Protocol, storage and transport tests use fakes or loopback endpoints. Actual Mac receiver input tests additionally require verified Yomado virtual-display/input isolation.
