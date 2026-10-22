# Sofatap Android TV receiver

This is the Android/Google TV experimental receiver for **free manual control**. It uses a native TV pairing screen and the existing Sofatap iPhone touch surface. No model account or paid inference is involved.

**No physical TV model or third-party TV app is qualified yet.** A successful build, network connection, or visible cursor does not establish that a television accepts clicks. This is not a Google Play release.

The published [0.2.1 beta.1 development APK](https://github.com/chekusu/sofatap/releases/download/android-tv-v0.2.1-beta.1/Sofatap-Android-TV-0.2.1-beta.1.apk) (version code 7) pairs with **iPhone 1.0 build 17 or later** for automatic reconnection. It fixes text from the iPhone being rejected while the Android editor is still active, keeps the receiver update controls added in 0.2.0 beta.1 and retains the native Start with TV option; see the [release notes and checksum](https://github.com/chekusu/sofatap/releases/tag/android-tv-v0.2.1-beta.1), [0.2.1 release verification](../docs/verification/android-tv-release-0.2.1-2026-10-22.md), [0.2.0 release verification](../docs/verification/android-tv-release-0.2.0-2026-10-17.md), [startup verification](../docs/verification/receiver-autostart-2026-10-16.md) and [recovery verification](../docs/verification/android-tv-reconnect-2026-10-16.md). Sony XRJ-85X95L (Android 12) and Xiaomi MiTV-MOEU0 (Android 14) have completed limited installation/setup checks. Xiaomi’s same-signed 0.1.4 candidate preserved pairing and accessibility; its Sofatap input method was enabled and selected. Native Remote Service pairing and actual YouTube/Netflix/browser input remain pending on both TVs; see the [hardware results](../docs/verification/tv-native-controls-2026-10-17.md). Neither model has completed acceptance.

## Native remote and text preview (introduced in 0.1.4-beta.1)

The receiver includes a separate native TV remote mode and an optional Sofatap keyboard. It requires iPhone 1.0 build 20 or a later matching build with the `tvControls` extension. It has not yet passed physical Sony/Xiaomi or third-party-app acceptance.

After the usual Sofatap QR pairing, choose **Set up TV remote** on the phone and enter the six-character hexadecimal code shown by the TV. The receiver talks only to the TV's own Android TV Remote Service on loopback ports 6467 (pairing) and 6466 (control). The normal code challenge authorizes an encrypted, persistent client identity and pins the TV certificate. A changed certificate requires explicit pairing again. No ADB, model account or accessibility focus substitution is used for these native keys. Android TV Remote Service must be installed and enabled; it is not present on every Android-based television.

For phone typing or speech-to-text, use **Enable Sofatap keyboard** and **Select Sofatap keyboard** on the TV, then open an ordinary text field in the target app. These are Android's normal input-method setup screens; Sofatap cannot enable or select itself silently. Your phone commits Unicode text through the currently selected input method. Backspace removes a selection or one Unicode code point; this is not a promise to remove an entire multi-code-point emoji or grapheme. The action button uses the current editor's supported action. Password fields and locked/asleep screens reject text. Keyboard availability depends on the app exposing a real Android input connection.

The phone session and the current editor epoch are checked immediately before input. Editor changes, restarts and disconnects invalidate old epochs. Sofatap sends no field contents back to the phone, logs no entered text or pairing codes, and never replays uncertain input. A successful native-key ACK means the key was written to the authenticated Remote Service; it does not independently verify the resulting TV screen.

## Receiver updates (0.2.0-beta.1)

The published direct-download receiver provides native **Check for updates**, **Install update**, and **Download updates automatically** controls. Automatic downloading is enabled by default, can be disabled, and checks once a day while the foreground receiver is running. Stopping the receiver cancels its automatic transfer/check schedule. A manual check can be retried after one minute; GitHub rate limits delay both manual and automatic checks. Background work never opens an installer over the current TV app.

The current beta follows Android TV beta and stable releases; a stable receiver only follows stable releases. Desktop receiver releases are excluded. Checks read the fixed public `chekusu/sofatap` GitHub releases API, with ETag caching, pagination and bounded request/download budgets. This sends a standard updater user agent and the network request to GitHub; no phone/TV identifiers, pairing credentials, input text or private app data are sent.

Before offering installation, the APK must have the exact official release asset name and HTTPS URL, uploaded state, a matching GitHub SHA-256 asset digest and declared size, the `com.chekusu.sofatap.tv` package, an exact matching version name, a strictly higher Android version code, and the same current signing certificate set as the installed receiver. Installation rechecks the private cached APK. Missing digests, signature changes, altered files and downgrades fail closed. Downloads are limited to 100 MiB; the private cache retains at most one ready APK, one temporary transfer and five metadata pages. Interrupted downloads are removed. Pairings, settings and permissions are preserved by Android's ordinary same-package update; Sofatap never uninstalls or clears data to resolve a signature mismatch.

**Android requires the user to approve installation.** Choose **Install update** in Sofatap. If necessary, Android opens the normal “Allow from this source” setting; after enabling it, return and choose Install again. Once the verified package is prepared, choose **Continue installation** to open Android's installation confirmation. Background checks never grant this permission or confirm installation. There is only one persisted pending installer session. If the app process dies before its confirmation screen can be opened, cancel the pending session in Sofatap and retry. Cancelling preserves the current receiver. Manufacturer policies can prohibit sideload installation even with a valid APK.

A Google Play distribution must be built with `-PsofatapDistribution=play`. That artifact omits `REQUEST_INSTALL_PACKAGES`, disables self-download/install, and sends **Check for updates** to the native Play Store. A direct build installed by Google Play also disables self-updating at runtime. This is preparation for a future Play distribution, not evidence of Play acceptance. Current public APKs retain the existing development signing key; the installer accepts only an exact match.

The update implementation is verified with offline release/transfer fixtures and a disposable Android TV emulator; installation through the new system-installer flow on physical Sony/Xiaomi TVs still needs its own acceptance. See [the updater verification record](../docs/verification/android-tv-updates-2026-10-17.md) and [published artifact verification](../docs/verification/android-tv-release-0.2.0-2026-10-17.md). Earlier receiver versions need one manual upgrade to 0.2.0 beta.1 before these controls are available.

## Build

Requirements: JDK 17, Gradle 8.13, Android SDK Platform 36, and Android SDK Build Tools 35.0.0. Android Gradle Plugin 8.13.0 is declared by this project. The minimum device version is Android 8.0 / API 26; the compile and target SDK are 36.

Set `ANDROID_HOME` to your installed Android SDK directory and `JAVA_HOME` to your JDK 17 directory. From this `android` directory, run:

```sh
./gradlew :receiver:testDebugUnitTest :receiver:lintDebug :receiver:assembleDebug
```

The development APK is written to `receiver/build/outputs/apk/debug/receiver-debug.apk`. It uses a development signing key. A future Google Play submission requires a release-signed Android App Bundle and the relevant TV and Accessibility API review; neither is supplied by this debug build.

## Install and pair

Install the APK on a test television using its supported local APK installation method. For a developer-owned device with debugging already enabled and explicitly authorized, an alternative is:

```sh
adb -s DEVICE_SERIAL install -r receiver/build/outputs/apk/debug/receiver-debug.apk
```

ADB is only an optional development installation tool. It is not the control transport and is not used to grant accessibility access.

1. Open Sofatap from the television's app launcher. Connect the TV and iPhone to the same trusted home network.
2. Using the physical TV remote, open Accessibility settings from Sofatap, read the explanation, and enable its service. Menu names and availability vary by manufacturer and firmware.
3. The receiver starts automatically on first launch. On the iPhone, open **My Devices → Add Device → Scan QR Code**, then scan the TV’s native pairing QR code. Its device type and suggested name are recognized automatically.
4. Try a known harmless control first. Pointer movement and successful activation are separate observations; verify the visible result of each click and scroll.

The QR code expires after five minutes and carries private pairing credentials. Do not share or publish it. Pairing another iPhone replaces the previous pairing. The receiver uses a pinned TLS WebSocket on the local network; no browser or cloud relay is needed. Stop the receiver to end the network session, and disable Sofatap in Accessibility settings to remove its control access.

## Start with TV

The native **Start with TV** switch is on by default after opening this version once. It starts the foreground receiver after the TV boots without opening the pairing screen or interrupting the current app. You can switch it off at any time; that choice survives app launches and updates. Turning it off does not end the current connection. **Stop receiver** ends the current run; when startup remains enabled, the next TV reboot starts it again. An app update only restores a receiver that was running, so it does not undo Stop.

The listener can recover after Android reclaims its process, and it waits for Wi-Fi or Ethernet to return. Neither this setting nor Android's service recovery can bypass Force stop, manufacturer background restrictions, a powered-off TV, or accessibility permission. After Force stop, open Sofatap again. Boot startup is after the Android user is available; it does not run against locked encrypted storage. Sony and Xiaomi startup/standby behavior still requires physical-TV testing.

This uses Android's [boot/package-update foreground-service exemptions](https://developer.android.com/develop/background-work/services/fgs/restrictions-bg-start) with the [connected-device service type](https://developer.android.com/develop/background-work/services/fgs/service-types#connected-device). It requests no alarm, wake lock, or battery-policy bypass.

## Reconnection

After successful pairing, iPhone build 17 retries the selected Android TV while Sofatap is in the foreground, with delays of 1, 2, 4, 8, 16 and then 30 seconds. Restarting the receiver with the same valid address and identity does not require another scan. Adding or removing an unrelated network adapter, or briefly starting without a network, preserves a valid saved identity. QR codes only advertise currently reachable addresses covered by the certificate. A genuine address replacement or certificate expiry can require pairing again.

Manual disconnect, removing the device, switching targets and backgrounding cancel pending retries. Returning to the app reconnects the selected saved TV unless it was explicitly disconnected. Certificate or authentication failures stop automatic attempts and require user action. QR bootstrap credentials are never retried; queued and unconfirmed gestures are discarded rather than replayed after recovery. This does not wake a sleeping TV or bypass its lock screen.

The APK is development-signed. `adb install -r` preserves app data only when the installed package has a compatible signing certificate. Earlier CI-generated debug APKs can have a different certificate; do not uninstall or clear pairing data to hide a signature mismatch. Keep the installed build until an explicit migration is arranged.

## Current capabilities

| Capability | This build |
| --- | --- |
| Visible pointer | A non-intercepting accessibility overlay, bounded to the TV's default display |
| Click | Activates an accessible control beneath the pointer; dependent on the target app's exposed UI structure |
| Scroll | Uses exposed scroll-container actions; bounded page-style steps rather than arbitrary mouse-wheel injection |
| Directional focus | Separate accessibility input-focus navigation; it is not mouse movement or injected D-pad keys |
| Native D-pad / OK / Back / Home | Separate Remote v2 adapter; requires explicit TV code pairing, independent of accessibility pointer permission |
| Legacy Back / Home | Android accessibility global actions while the screen is available |
| Text and dictation | Optional, user-enabled/selected Sofatap keyboard; current non-sensitive Android editor only |
| Drag / right-click / raw mouse events | Not implemented |

Clicks refresh and recheck nodes before acting. Overlapping ambiguous controls, password/sensitive nodes, known protected system surfaces, and the receiver's permission/pairing approval controls are rejected. Screen lock, screen-off, interruption and disconnect cancel control and hide/reset the pointer. The service does not request touchscreen gesture injection and does not depend on a touch-screen feature.

The first Sony test confirmed installation, user-granted accessibility access, pairing, clicks and some scrolling. The user clarified that clicks do work; the earlier apparent failure may have been a delay behind scrolling. Rapid scrolling disconnected the iPhone client, and Back still needs a successful field retest. A separate read-only snapshot of one transient YouTube TV screen exposed no `ACTION_CLICK` nodes. That snapshot does not identify the cause of the user's earlier observation or establish that YouTube clicks are unsupported. Clickable controls vary by screen; focus confirmation also requires an exposed click action and is not a universal fallback. The rapid-scroll client queue issue is being addressed separately.

The accessibility API does not expose a universal guarantee for every protected OEM screen or app. The implementation deliberately avoids reading or recording control text and does not transfer UI trees. Its `framework_accepted` response means Android/the target app accepted an action request; it does not prove that the intended screen change occurred.

## Troubleshooting and acceptance

- **Connected, but no pointer input:** confirm Sofatap is enabled in Accessibility settings and the TV is awake and unlocked. Network pairing does not grant pointer permission.
- **Native keys unavailable:** complete the separate TV-code pairing from the phone. Do not substitute accessibility node focus and call it native D-pad support.
- **Text unavailable:** enable and select Sofatap keyboard using the TV's normal settings, then focus an ordinary editor. Protected fields remain unavailable.
- **Pointer moves, but a click fails:** the target may expose no accessible clickable node or may be protected/ambiguous. Record the app, screen and returned error without private content; do not label pointer movement as full mouse support.
- **No pairing address:** connect to home Wi-Fi or Ethernet, then stop and start the receiver. Guest-network isolation can prevent the iPhone from reaching the TV.
- **Expired QR:** use “Pair another iPhone” to generate a fresh code. This revokes the previous pairing.
- **Missing Accessibility entry:** record the exact model, firmware and menu availability. Do not use root/ADB permission bypasses as a consumer setup path.

Before claiming support for a model, verify native pairing, reconnect/revocation, a visible pointer, real click outcomes, scrolling, focus navigation, Back/Home, permission removal and lock/disconnect behavior on that TV. Test ordinary Settings, the launcher and representative apps independently. The new native-key and text paths still require separate physical acceptance, including YouTube/Netflix navigation and a browser editor. The software-only tests do not establish those app results.

See [the TV implementation plan](../docs/research/tv-implementation-plan.md) and [the product roadmap](../docs/ROADMAP.md). LG webOS remains a separate adapter.

## Reproduce software validation

Run `./gradlew :receiver:assembleDebug :receiver:assembleDebugAndroidTest :receiver:testDebugUnitTest :receiver:lintDebug`. The JVM suite uses fake input and real local TLS sockets, including Remote v2 code proof, pin-change rejection, seven native key codes and cancellation before a queued write. The IME suite covers Unicode, selection deletion, editor epochs and sensitive fields. On macOS, after these dependencies have resolved, `SOFATAP_JAVA_HOME="$JAVA_HOME" bash ../ios/scripts/test-android-tv-interop.sh` verifies the actual Swift URLSession client against the Java server with a counting input fixture. It uses a private local IPv4 interface and deletes its temporary pairing material afterward.

For device-runtime tests, create a **disposable Android TV emulator**, start it with `-no-window -no-audio -no-snapshot`, and run `bash scripts/test-emulator.sh emulator-SERIAL`. The runner refuses physical devices. The instrumentation temporarily enables the accessibility service inside that disposable emulator, exercises a debug-only, non-exported fixture, and restores the previous permission setting. This is an automated test setup, not the consumer permission flow. The additional IME tests use a private EditText/InputConnection fixture and do not change the system-selected keyboard. No host desktop input is generated. Read [the verification record](../docs/verification/android-tv-probe.md) for exact results and hardware limitations.
