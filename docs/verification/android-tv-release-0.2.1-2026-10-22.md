# Android TV receiver 0.2.1 beta.1 release — October 22, 2026

Android/Google TV receiver **0.2.1-beta.1**, version code **7**, is [publicly released](https://github.com/chekusu/sofatap/releases/tag/android-tv-v0.2.1-beta.1) as a prerelease. Desktop receivers, the Android phone controller and iPhone/TestFlight distribution are unchanged by this release.

## Change

Text sent from the iPhone could be rejected as `stale_editor` ("TV field changed") while the Android editor was still active: Foundation encodes the editor UUID in uppercase, while the receiver compared it against a lowercase Java UUID. The receiver now compares the canonical UUID ([PR #14](https://github.com/chekusu/sofatap/pull/14), reported in [#13](https://github.com/chekusu/sofatap/issues/13)). Different or expired editors and expired controller sessions are still rejected.

## Source and artifact

- Built from clean commit `c615863ff7db3463329063836d613d66f222856c` on `main` ([PR #21](https://github.com/chekusu/sofatap/pull/21) version bump; all five CI jobs passed on that head).
- Package: `com.chekusu.sofatap.tv`; APK: [Sofatap-Android-TV-0.2.1-beta.1.apk](https://github.com/chekusu/sofatap/releases/download/android-tv-v0.2.1-beta.1/Sofatap-Android-TV-0.2.1-beta.1.apk), **6,355,504 bytes**.
- APK SHA-256: `0ff6513ce5dac77a898583356ecc2de1339659296eb2c1521818da76dc0b4e51`.
- Signing certificate SHA-256: `638afe6aadb3c2d76001ef682c6a48b0f3243755fa9ae131b9804eed36ede4d9`, identical to the published 0.2.0 APK (downloaded, checked against its published digest, and compared). This keeps the development/debug signing identity required by the in-app updater; it is not a Google Play release.
- Anonymous download of the published APK returned HTTP 200 and matched the local artifact's byte count and SHA-256.

## Verification and boundaries

The release source passed **135 JVM tests**, Android lint with no errors, and **28 instrumentation tests** on a disposable headless Android TV API-31 emulator, which was stopped afterwards. No household TV was used.

Receivers running 0.2.0 beta.1 can update through **Check for updates → Install update**; older receivers install the APK over the previous package without uninstalling. The reported Android 16 phone with Brave/Telegram, physical TV compatibility and real iPhone keyboard timing remain unverified.
