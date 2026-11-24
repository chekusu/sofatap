# Windows native receiver window

`SofaTap.exe` is a native WinForms application. It starts the bundled `SofaTapHost.exe --native-ui` with redirected pipes and no console window. The QR code is a native bitmap inside the window; no browser or WebView is involved. Closing the window hides it in the system tray and keeps the receiver running. Clicking Quit requests graceful backend shutdown and waits before exiting.

The Mint Calm frontend keeps QR images and optional, validated `sofatap://pair` links only in memory. The explicit **复制配对链接** (Copy pairing link) button is the only operation that writes the selected link to the clipboard; missing or malformed optional links leave QR-only snapshots usable with Copy disabled. Pairing links are excluded from model serialization and diagnostic strings. The frontend does not write pairing snapshots or links to files or logs. Backend stderr is drained privately rather than shown verbatim. Ordinary remote text input keeps its existing clipboard-free path.

The native Windows frame, keyboard navigation and accessible names remain intact. The content uses the shared [Mint Calm palette](../../docs/RECEIVER-DESIGN.md), an unmodified black/white QR with nearest-neighbor scaling, a selectable actual network address and visible keyboard focus. Short windows scroll; narrow windows stack the computer name and address. A failed or stopping receiver clears the QR and disables Copy.

The pipe reader bounds frames while reading, including output that never sends a newline. Malformed state or an unexpectedly closed state pipe clears the QR and requests shutdown of the owned backend. The five-second graceful-shutdown deadline includes waiting for the command writer and sending Quit. On expiry the window stops only its own process tree, then waits at most two more seconds. A shutdown error keeps the window open for a retry.

Build the complete self-contained Windows x64 folder and ZIP from the repository root with `bash scripts/build-windows.sh`. Both executables and every additional file in the archive belong together. The default executable needs no separately installed .NET runtime. The build can cross-compile on macOS using the .NET 10 SDK; an actual Windows desktop is still required for native-window and input acceptance.

For developer transport checks, launch `SofaTap.exe --dry-run`; the native window labels input as disabled. The normal executable starts with input enabled when the Windows desktop is available. Portable parser and child-process checks can run with `dotnet run --project desktop/windows/tests/ProtocolChecks.csproj`; they do not substitute for real WinForms rendering tests.

For Windows CI rendering, run `dotnet run --project desktop/windows/preview/MintCalmPreview.csproj -c Release -- artifacts/mint-calm`. The [offline fixture harness](preview/README.md) links the real window but never starts the receiver, opens a listener, writes the clipboard or sends desktop input. Its five PNGs cover ready, permission, failure and narrow/scrolled layouts with a non-pairing DEMO QR. Native rendering is separate from physical Windows/iPhone acceptance.

## Updates

The receiver's system-tray menu has **检查更新…** (Check for Updates), **自动下载更新（下次打开时安装）** (automatic downloads; enabled initially), and **安装更新并重启…** (Install and Restart). The automatic preference persists in the current user's LocalAppData. Turning it off also stops a previously downloaded update from installing automatically. A manual check remains available. Automatic discovery runs at launch and then on an hourly timer, with a 24-hour successful-check interval and exponential error backoff. GitHub API pages use ETags; repeated manual checks are limited to once per minute.

Desktop releases use numeric semantic `v` tags; `android-tv-` tags are excluded. Beta installations accept newer beta or stable versions. Stable installations stay on stable releases. Downloads must be the exact official `chekusu/sofatap` Windows asset, with uploaded status, bounded size, and GitHub's SHA-256 asset digest. Missing or invalid verification metadata fails closed. ZIP entries, per-file hashes, the version/architecture manifest, archive paths, alternate streams, duplicate names, symlinks and extraction sizes are validated before offering installation and revalidated immediately before replacement.

An automatic download never stops an active receiver. It waits until the next ordinary launch, before starting the backend. **Install and Restart** asks for explicit confirmation, gracefully stops only the owned backend, and then runs a copy of the current executable as the updater. The updater waits for the current UI process to exit, stages beside the installation, and replaces the directory using same-volume renames. It requires the new receiver to emit its first valid backend state within 45 seconds; failure stops only that replacement process and restores the previous directory. Existing pairing/TLS/configuration files in LocalAppData are untouched, the installation path and startup shortcut remain stable, and unrecognized files inside the install folder are preserved unless they conflict with a new package file (which blocks the update).

Previous versions are retained in a sibling `.Sofatap-backup-<id>` folder for manual recovery; failed replacements are retained separately. These backups are not silently deleted. Protected or linked installation directories may require a manual update; this updater does not elevate privileges. Packages from before this feature need one ordinary manual upgrade to acquire the updater and its file manifest. `--dry-run`, preview fixtures and the test suite never check, download or install an update.

The cross-platform tests exercise release selection, integrity checks, malicious archives, preserved files, bounded streams and directory rollback with inert temporary fixtures. Cross-compilation and these tests are not a substitute for a Windows end-to-end updater test, native tray UI acceptance, or real phone input testing.

## Notification-area menu

The receiver runs from the notification area.

- A left click opens the pairing window.
- A right click opens a native menu. The computer's state is at the top, followed by:
  - 显示配对二维码 (this becomes 配对新 iPhone once a phone is connected)
  - 复制配对链接
  - 刷新
  - 登录后启动
  - the update items
  - 退出

Closing the window leaves the receiver running in the notification area. A moment after a phone connects, the window hides back to the notification area on its own.
