# Receiver updates

Desktop **0.8.1 beta.1** and Android/Google TV **0.2.0 beta.1** include native update controls. Earlier receiver versions require one manual upgrade to acquire the updater. The published Apple Silicon and Intel Mac feeds and notarized ZIPs have verified signatures. Installing an iPhone update does not update a computer or TV receiver.

| Client | Check for updates | Automatic behavior | Installing |
| --- | --- | --- | --- |
| Windows | Right-click the Sofatap tray icon → Check for updates | Enabled by default; checks daily and downloads a verified package | Applies before the next receiver launch, or choose Install and Restart. Explicit restart asks before disconnecting the phone. Closing the window still hides to the tray. |
| macOS website app | Sofatap menu → Check for updates | Enabled by default; Sparkle checks daily and downloads signed updates | Installs through Sparkle on normal quit. Explicit Install and Relaunch waits until the phone disconnects. |
| Linux portable package | Native window → Check for updates | Enabled by default; checks daily and downloads a verified package | Applies before the next receiver launch, or choose Update and Restart while disconnected. A user-owned writable installation directory is required; system-managed installations need a manual update. |
| Android / Google TV APK | Receiver → Check for updates | Enabled by default; daily checks/downloads while the receiver service runs | Choose Install update, grant Android's installation permission if asked, then Continue installation to open Android's confirmation. Background checks never open an installer over another TV app. |
| iPhone / iPad | TestFlight or App Store | Managed by Apple's app and the user's system settings | Install updates in TestFlight/App Store. Sofatap cannot silently replace its own iOS binary. |
| Mac App Store basic build | Native menu opens App Store Updates | Managed by the App Store | The store build excludes Sparkle. Its store listing is a separate release process. |

The automatic option can be turned off and the choice persists across launches and upgrades. Manual checks remain available. Desktop stable releases do not move users onto a prerelease channel; the current public beta can take newer beta or stable releases. Android and desktop versions are separate release streams.

## Integrity and data

Windows, Linux and APK discovery uses the fixed official `chekusu/sofatap` repository. The updater selects the matching platform/architecture asset, requires the GitHub API's SHA-256 digest and exact byte count, and rejects malformed metadata, unexpected download hosts, incomplete downloads and version downgrades. Archive extraction rejects links and unsafe paths. This is verification against the official HTTPS release metadata; Windows binaries remain unsigned by Authenticode.

Windows uses a copied current updater executable, an installation-bound ticket, same-volume staging and a retained previous-directory backup. The replacement must report a valid backend state; failure stops that replacement and attempts to restore the old directory. User pairing data remains outside the installation directory. Unmanaged installation files are retained unless they conflict with the new package, in which case installation stops.

Linux validates the archive, package version/architecture, executable permissions, backend `--help` startup and Python syntax before replacement. It retains a previous-directory backup and rolls back a failed directory replacement. It does **not** yet supervise GTK or desktop-input health after a completed restart; keep the backup if the new app fails at runtime. Pairing/preferences stay in their original user data locations, and unmanaged package files are preserved or cause a conflict error. No sudo or package-manager settings are changed.

The macOS website build uses pinned Sparkle 2, signed appcasts and Ed25519 archive signatures, plus Developer ID signing and Apple notarization. The private update key stays in the release Mac's Keychain. See [publishing instructions](../scripts/macos/UPDATES.md). Android verifies the APK package name, higher version code, matching version name and installed signing certificate before handing it to the system installer. APK updates preserve app data. Play builds/installations disable the external installer path.

Update checks send ordinary requests to GitHub (or the signed GitHub-hosted Mac feed), without pairing credentials, input content or a device identifier. Network/server failures keep the installed receiver usable. Checks/downloads are separate from successful installation; a built package is separate from a published release and from a tested physical-device upgrade.

## Website and publishing

The website should resolve the latest complete desktop release separately from the latest complete experimental Android/Google TV release. Do not use GitHub's `/releases/latest` endpoint for both products: prereleases are currently used and Android tags are independent. Publish only complete, verified assets, keep the last known good links on lookup failures, and validate every localized download page. The iOS public invitation remains [Join TestFlight](https://testflight.apple.com/join/e6MuKx9S).

For each receiver release, update package versions, run regression/build checks, publish the verified artifacts, and then publish matching signed Mac feeds. Confirm anonymous downloads and production website links. Existing active phone connections must not be used as upgrade test targets without a scoped acceptance session.
