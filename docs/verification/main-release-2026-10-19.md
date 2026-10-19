# Main release: desktop 0.8.1 beta.1 and iOS 1.0 (22)

Release source: `e798f8db485555b27990cc53e2eae7fff27fbc53`, after merging independently reviewed [PR #17](https://github.com/chekusu/sofatap/pull/17). The [main CI run](https://github.com/chekusu/sofatap/actions/runs/39239834906) passed all four platform jobs.

## Desktop artifacts

[Desktop 0.8.1 beta.1](https://github.com/chekusu/sofatap/releases/tag/v0.8.1-beta.1) includes Windows x64, Linux x64/ARM64, and Mac Apple Silicon/Intel packages built from the clean source revision above. Anonymous HTTP downloads of all five packages and the release manifest returned 200 on 2026-10-19. Their exact byte sizes and SHA-256 hashes match the published manifest.

Both Mac packages use CHEKUSU Developer ID signing, hardened runtime, and secure timestamps. Apple accepted notarization; stapling, nested code signatures and Gatekeeper checks passed. Mac bundle build is 110. Package and appcast Ed25519 signatures were independently verified with the configured public key. Using the real signed appcasts, an isolated Sparkle probe found build 110 from build 107 and reported build 110 as up to date. The probe did not install an update or launch the receiver.

Windows packaging regression checks passed, with package metadata and architecture verified. Windows binaries are not Authenticode signed. Linux package architecture, executable permissions and source manifests were checked; this release does not establish new physical Linux input acceptance.

## Phone distribution and smoke test

The Release archive for iOS 1.0 (22) passed Apple processing and is available in the internal group. It was submitted and approved for external review on 2026-10-19. Apple reports APPROVED and both internalBuildState and externalBuildState as IN_BETA_TESTING. The existing internal and public groups contain Build 22, and the public TestFlight invitation accepts new testers. Build 22 is the latest uploaded build and is available to both groups.

A development-signed export of the same Release archive was installed on a dedicated physical iPhone SE. Main-screen launch, device management, gesture settings, keyboard expansion and keyboard hiding were checked. The test phone was returned to Home and its device lease released. No receiver was paired on that phone, so this smoke test does not establish physical end-to-end input or the paired Mac transport-selector UI.

PR-level transport, ACK, TLS and lifecycle regression evidence and contributor physical observations are recorded in [pointer transport verification](pointer-transport.md). Full radio-interruption acceptance and broader application compatibility remain pending.

## Unchanged TV acceptance

The Android/Google TV receiver remains 0.2.0 beta.1. This release includes neither the pending TV shortcut work nor new Sony/Xiaomi field acceptance. PRs with outstanding device acceptance were not included merely because this release passed its own checks.
