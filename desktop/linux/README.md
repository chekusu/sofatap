# Sofatap receiver for Linux

Use your iPhone as a touchpad, mouse and keyboard for a Linux computer. Pairing happens in a native GTK window. The Mint Calm design uses the same charcoal canvas, pairing card and mint action as the macOS and Windows receivers, while preserving native window controls. Sofatap does not open a browser or serve a local pairing website.

The receiver needs a logged-in graphical Linux desktop. It is not a headless remote-login service. Builds are available for x86-64 (`x64`) and 64-bit ARM (`arm64`). The self-contained backend includes .NET; Python, GTK and the desktop input libraries remain system dependencies.

## Start the packaged receiver

1. Download the archive for your computer's architecture and extract it.
2. Install the dependencies listed below using your distribution's package manager.
3. Open the extracted folder and run `./sofatap`. Depending on your file manager, you can also double-click the executable and choose **Run**.
4. On Wayland, click **允许控制桌面** and approve the desktop's native permission prompt. If you decline, the receiver cannot control the desktop; the same button lets you try again.
5. Connect the iPhone and computer to the same trusted home network. Choose the reachable address in Sofatap's window, then scan its QR code in the iPhone app.

The status must read **桌面已就绪** before mouse or keyboard input is available. A successful network connection alone does not grant desktop control. **复制配对链接** copies the selected address's pairing link only when you click it; older receivers or invalid optional links leave this action disabled while QR pairing stays available. The link and QR code grant control: never share them or screenshots containing a live QR.

The first normal launch enables **登录后自动启动** (start after login). The native checkbox can turn it off; a removed or disabled entry is never silently restored. Keep the extracted package in a permanent location. If you move it, turn the option off and back on from the new copy to update its path. Login startup uses the standard per-user XDG autostart directory, requires no root access and does not run before desktop login.

Closing the normal window minimizes it and keeps receiving control. Reopening Sofatap restores the existing window rather than launching another backend. Click **退出** to stop receiving until the next launch or login; turn off login startup to stop future automatic launches. Closing a Wayland permission session also ends its input access; login startup does not bypass the portal authorization. Sofatap does not install a system service or modify firewall rules. If your distribution's firewall blocks the connection, allow TCP 53319 only on your trusted home network through the distribution's normal firewall settings.

## Desktop support and dependencies

Python 3.10 or newer, PyGObject and GTK 3 are required. Use a distribution supported by the bundled .NET 10 runtime, such as Ubuntu 24.04 or 26.04. Minimal installations may also need their [normal .NET native prerequisites](https://learn.microsoft.com/en-us/dotnet/core/install/linux-ubuntu-install); the runtime does not bundle glibc or OpenSSL. These packages target glibc Linux, not Alpine/musl.

- **X11:** a logged-in X11 session with the XTEST extension and `libX11` / `libXtst` / `libxdo3`. UTF-8 text uses libxdo and temporary, per-action Unicode key mappings; the clipboard is not read or overwritten. Input uses that session's standard X11 authorization. Do not run the receiver with `sudo`, disable X11 access control with `xhost +`, or expose the X server to the network.
- **Wayland:** a desktop portal implementing [`org.freedesktop.portal.RemoteDesktop`](https://flatpak.github.io/xdg-desktop-portal/docs/doc-org.freedesktop.portal.RemoteDesktop.html) (version 1 or newer) and its pointer/keyboard notification methods, together with the matching portal backend for your desktop. Both keyboard and pointer access must be granted. Portal support varies by desktop and version. Unsupported desktops show an unavailable status and receive no injected input. A running XWayland server by itself does not provide full Wayland desktop support.

For Ubuntu/Debian, the typical packages are:

```sh
sudo apt install python3 python3-gi gir1.2-gtk-3.0 libx11-6 libxtst6 libxdo3
```

PyGObject also provides the Gio/GLib bindings used to communicate with the native portal. A normal GNOME or KDE Wayland installation also provides `xdg-desktop-portal` and its matching GNOME/KDE backend. Install or repair them using your desktop's own package documentation; do not install an unrelated backend merely to suppress an unavailable status. Sofatap never launches an installer automatically.

Sofatap sends Wayland text as XKB keysyms. Unicode support depends on the compositor and destination application; verify your text in the target application. Both Linux backends accept at most 2,048 Unicode characters per text action (after normalizing CRLF); split longer text before sending. X11 may reject a shorter selection before typing if its distinct characters exceed the available temporary key slots, or its estimated input time exceeds the action budget. A slow portal may report partial input: check the computer before resending, because retrying can duplicate text. Ordinary remote text input does not read or overwrite the clipboard. The native Copy pairing link action writes the selected link to the clipboard explicitly; it never reads its previous contents. The receiver does not request screen-capture access or persist a portal restore token.

Dictation and third-party iPhone keyboards work through Sofatap's text field: finish composing, review the text, then send it to the computer's focused application. This Linux implementation still needs physical iPhone acceptance testing; automated protocol checks and virtual desktop tests do not prove microphone, voice keyboard or real-device behavior.

Development version 0.5.0 can report focused editable fields through an optional AT-SPI helper. On Debian/Ubuntu it uses the existing `python3-gi`/Gio runtime and a working accessibility bus (normally `at-spi2-core`), with apps that expose accessible text state. It does not require the Atspi typelib. This is separate from Wayland input permission. No accessibility settings are changed automatically. Unsupported applications/sessions retain manual keyboard input, and startup waits for a focus event. Only a field classification and connection-local revision are sent to the phone, never its contents; see [focus detection](../../docs/TEXT-FOCUS.md).

## Optional applications-menu entry

The package includes a `sofatap.desktop` template and `sofatap.png`. The template expects `sofatap` to be on the desktop session's `PATH`. To register it just for your account, keep the extracted folder in a permanent location, then run from that folder:

```sh
mkdir -p ~/.local/bin ~/.local/share/applications ~/.local/share/icons/hicolor/1024x1024/apps
ln -s "$(pwd)/sofatap" ~/.local/bin/sofatap
cp sofatap.desktop ~/.local/share/applications/sofatap.desktop
cp sofatap.png ~/.local/share/icons/hicolor/1024x1024/apps/sofatap.png
```

Ensure `~/.local/bin` is in your desktop session's `PATH` (a logout/login may be needed). The link command deliberately refuses to replace an existing command. Removing those three installed files removes the menu entry; the application itself remains in the extracted folder. This does not create a startup item.

## Build from source

From the repository root with the .NET 10 SDK installed:

```sh
bash scripts/build-linux.sh x64
# Or: bash scripts/build-linux.sh arm64
```

The resulting `artifacts/SofaTap-Linux-<architecture>.tar.gz` contains the native Python/GTK frontend, a self-contained Linux backend, the Linux input worker, licenses and a build manifest with source revision and SHA-256 hashes. The architecture can be cross-built on macOS; that is not evidence the package ran on Linux.

For development, you can launch the native frontend against a locally published backend:

```sh
python3 desktop/linux/sofatap.py --backend /absolute/path/to/SofaTap
```

`--startup` starts the normal receiver minimized and is used by the login entry. `--dry-run` is an explicit preview mode that never registers login startup. It preserves native pairing and connectivity but sends no desktop input and makes no permission request. Normal launches enable the platform's input backend only when desktop access is available.

## Lifecycle and checks

Pairing snapshots arrive as JSON lines over the owned child's private pipe. PNG bytes and optional validated pairing URIs remain in memory. A URI must use the phone's `sofatap://pair` format (four required security/endpoint fields, optional platform and bounded device name) and match the selected endpoint. Missing or invalid URIs disable Copy without rejecting a usable QR snapshot. Upgrade the iPhone app before scanning a metadata QR; iOS 1.0 build 14 and earlier only accept the older four-field codes. Links are never shown as text, logged, saved to disk or automatically copied; only an explicit Copy action writes the selected link to the clipboard. Backend diagnostics are drained without being copied into the interface or logs.

The frontend rejects unknown platforms, unknown input states, mismatched real/dry-run modes, malformed snapshots and oversized frames. A broken state pipe, or twelve seconds without a valid snapshot, clears the QR and stops the owned child. Commands have bounded nonblocking writes. Graceful shutdown has eight seconds in total, then only the owned child is terminated (two seconds) or killed (two seconds) if necessary. If shutdown still fails, the native window keeps Quit available for a retry.

Run `python3 desktop/linux/check_autostart.py` for temporary-profile startup, opt-out, exact Exec escaping and single-instance checks. On Linux it launches a harmless argument-capture process through the real Gio desktop-entry parser. No real login entry is written.

Run `python3 desktop/linux/check_protocol.py` for portable frontend protocol and process-lifecycle checks. These checks start no GTK window, generate no real mouse/keyboard events and require no paired phone. Actual rendering, supported desktop sessions and physical input have separate acceptance requirements.

On Linux, `SOFATAP_TEST_BACKEND=/absolute/path/to/SofaTap /usr/bin/python3 desktop/linux/check_gtk_integration.py` starts its own authenticated Xvfb server and temporary receiver profiles. It checks native GTK QR rendering, dry-run and X11 readiness, default startup and opt-out in a temporary profile, close-without-stopping and explicit Quit, owned worker cleanup and listener shutdown. It requires `xvfb` and `xauth` in addition to the runtime dependencies, never uses the current display and sends no mouse or keyboard events.

For offline visual review, run `/usr/bin/python3 -B desktop/linux/preview_mint_calm.py --output artifacts/mint-calm` on Linux with `xvfb`, `xauth` and CJK fonts (for example `fonts-noto-cjk`). It renders the production GTK window on its own authenticated private display and saves ready, permission-required and narrow-window PNGs. Ready and permission use the real 470 × 700 default; a second narrow PNG scrolls its native content to verify that footer actions remain reachable. The synthetic computer names, documentation IP addresses and DEMO pixel illustration contain no receiver credentials or usable QR. No backend, portal, clipboard action or real input starts. PNGs show the native client area without window-manager decorations; these previews do not establish real-device acceptance.

## Updating

Packaged builds from 0.8.0 beta.1 include **检查更新** and a default-on **自动检查并下载更新** option. Checks occur daily; downloads are validated and wait for the next receiver launch. **更新并重启** is available once downloaded and the phone is disconnected. Closing the window still minimizes without applying an update. Turn off automatic updates to prevent background checks and automatic installation; manual checks remain available.

Keep the portable folder in a stable directory owned by your user. System-owned/read-only installations require a manual update; no privilege elevation is attempted. Updates preserve external pairing/preferences and custom files, retain a backup next to the installation, and roll back failed directory replacement. Backend startup and syntax are checked before replacement; GTK/input failures after a completed restart do not yet trigger an automatic rollback. See [all platforms and integrity details](../../docs/RECEIVER-UPDATES.md).

Run `python3 -B desktop/linux/check_updates.py` for inert package tests covering version/channel selection, bad metadata, checksum failures, traversal/links, architecture, opt-out, rollback and custom-file retention. These do not establish real desktop upgrade acceptance.

## Notification-area menu

Some desktops support AppIndicator: KDE, Xfce, Cinnamon, Ubuntu's GNOME, and GNOME with the AppIndicator extension. On those, the receiver adds a native menu to the notification area with these items:

- the current state
- 显示配对二维码…
- 复制配对链接
- 刷新
- 退出

Indicator menus can't show images, so the pairing code stays in a small window. The first menu item opens that window. Closing it hides it back to the indicator. Launches with `--startup` start hidden.

If neither the AyatanaAppIndicator3 nor the AppIndicator3 GObject bindings are installed, the window minimizes to the task switcher as before. Dry-run previews never add an indicator.
