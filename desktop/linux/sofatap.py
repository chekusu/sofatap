#!/usr/bin/env python3
"""Native GTK3 receiver window for Sofatap on Linux."""

import argparse
import base64
import binascii
from dataclasses import dataclass, field
import ipaddress
import json
import os
from pathlib import Path
import re
import select
import struct
import subprocess
import sys
import threading
import time
import unicodedata
from urllib.parse import unquote, urlsplit

MAXIMUM_LINE = 4 * 1024 * 1024
STATE_DEADLINE_SECONDS = 12
SHUTDOWN_GRACE_SECONDS = 8
INPUT_STATUSES = frozenset({"dry_run", "ready", "permission_required", "permission_pending",
                           "permission_denied", "desktop_unavailable", "unsupported_session",
                           "dependency_missing", "input_unavailable"})
STATUS_LABELS = {
    "dry_run": "演练模式 · 不会控制电脑",
    "ready": "桌面已就绪",
    "permission_required": "请允许 Sofatap 控制此桌面",
    "permission_pending": "请在系统窗口中选择并允许控制桌面",
    "permission_denied": "尚未允许桌面控制，可点击下方按钮重试",
    "desktop_unavailable": "桌面会话不可用，请在本机桌面中重新打开",
    "unsupported_session": "此桌面暂不支持远程控制，请使用支持 RemoteDesktop portal 的 Wayland 桌面或 X11",
    "dependency_missing": "缺少桌面控制依赖，请查看随包的 README.md",
    "input_unavailable": "桌面控制已中断，可重新授权；若仍不可用，请重启接收器",
}
ACCESS_STATUSES = frozenset({"permission_required", "permission_denied", "input_unavailable"})


@dataclass(frozen=True)
class Pairing:
    host: str
    png: bytes
    uri: str | None = field(default=None, repr=False)


@dataclass(frozen=True)
class State:
    name: str
    connected: bool
    dry_run: bool
    input_status: str
    pairings: tuple[Pairing, ...]


def pairing_uri(value, selected_host):
    """Optional, memory-only copy payload; invalid links never invalidate a QR.

    Match the phone's pairing parser and the visible selected endpoint. Errors
    deliberately return no details that could expose credentials in diagnostics.
    """
    if (not isinstance(value, str) or not value.isascii() or not 1 <= len(value) <= 2048
            or any(ord(character) <= 32 or ord(character) == 127 for character in value)
            or "#" in value or re.search(r"%(?![0-9a-fA-F]{2})", value)):
        return None
    try:
        parts = urlsplit(value)
        if parts.scheme != "sofatap" or parts.netloc != "pair" or parts.path or parts.fragment:
            return None
        items = parts.query.split("&")
        if not 4 <= len(items) <= 6:
            return None
        fields = {}
        for item in items:
            key, separator, encoded = item.partition("=")
            if (not separator or key not in {"host", "port", "token", "fingerprint", "platform", "name"}
                    or key in fields):
                return None
            # URI queries preserve literal '+': this is not form-urlencoded data.
            fields[key] = unquote(encoded, encoding="utf-8", errors="strict")
        if not {"host", "port", "token", "fingerprint"} <= set(fields):
            return None
        host = fields["host"]
        if not host.isascii() or not 1 <= len(host) <= 253:
            return None
        if ":" in host:
            if "%" in host or ipaddress.IPv6Address(host) != ipaddress.IPv6Address(selected_host):
                return None
        elif (host.lower() != selected_host.lower()
                or any(not re.fullmatch(r"[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?", label)
                       for label in host.split("."))):
            return None
        port = fields["port"]
        if not re.fullmatch(r"[0-9]{1,5}", port) or not 1 <= int(port) <= 65535:
            return None
        if not re.fullmatch(r"[A-Za-z0-9_-]{32,256}", fields["token"]):
            return None
        if not re.fullmatch(r"[A-Fa-f0-9]{64}", fields["fingerprint"]):
            return None
        if "platform" in fields and fields["platform"] not in {"windows", "macos", "linux"}:
            return None
        if "name" in fields:
            name = fields["name"]
            if any(unicodedata.category(character) in {"Cc", "Cf"} for character in name):
                return None
            name = name.strip()
            if not name or len(name) > 80 or len(name.encode("utf-8")) > 256:
                return None
        return value
    except (ValueError, UnicodeError, AttributeError):
        return None


def parse_state(line, expected_dry_run=None):
    if len(line) > MAXIMUM_LINE:
        raise ValueError("Receiver state is too large")
    value = json.loads(line)
    if not isinstance(value, dict) or value.get("type") != "state":
        raise ValueError("Unexpected receiver message")
    if value.get("platform") != "linux":
        raise ValueError("Expected a Linux receiver")
    dry_run, input_status = value.get("dryRun"), value.get("inputStatus")
    if not isinstance(dry_run, bool) or not isinstance(input_status, str) or input_status not in INPUT_STATUSES:
        raise ValueError("Invalid input status")
    if (input_status == "dry_run") != dry_run:
        raise ValueError("Conflicting input mode")
    if expected_dry_run is not None and dry_run != expected_dry_run:
        raise ValueError("Receiver input mode changed")
    name, items = value.get("name"), value.get("pairings")
    if not isinstance(name, str) or not 1 <= len(name) <= 255 or not isinstance(items, list) or len(items) > 32:
        raise ValueError("Invalid receiver state")
    if not isinstance(value.get("connected"), bool):
        raise ValueError("Invalid connection state")
    pairings = []
    for item in items:
        if not isinstance(item, dict):
            raise ValueError("Invalid pairing")
        host, encoded = item.get("host"), item.get("qrPng")
        if not isinstance(host, str) or not 1 <= len(host) <= 255 or not isinstance(encoded, str) or len(encoded) > 1024 * 1024:
            raise ValueError("Invalid pairing fields")
        try:
            png = base64.b64decode(encoded, validate=True)
        except (binascii.Error, ValueError) as error:
            raise ValueError("Invalid QR encoding") from error
        if len(png) < 24 or png[:8] != b"\x89PNG\r\n\x1a\n" or png[12:16] != b"IHDR":
            raise ValueError("Invalid QR image")
        width, height = struct.unpack(">II", png[16:24])
        if not 1 <= width <= 2048 or not 1 <= height <= 2048:
            raise ValueError("Invalid QR dimensions")
        pairings.append(Pairing(host, png, pairing_uri(item.get("uri"), host)))
    # The validated URI stays in memory only for an explicit Copy button click.
    # It is never displayed, logged, persisted or automatically copied.
    return State(name, value["connected"], dry_run, input_status, tuple(pairings))


class Backend:
    def __init__(self, executable, on_state, on_failure, dry_run=False):
        self.executable = executable
        self.dry_run = dry_run
        self.on_state, self.on_failure = on_state, on_failure
        self.process = None
        self.stopping = False
        self.writer_lock = threading.Lock()
        self.shutdown_lock = threading.Lock()

    def start(self):
        arguments = [str(self.executable), "--native-ui"]
        if self.dry_run:
            arguments.append("--dry-run")
        self.process = subprocess.Popen(
            arguments,
            cwd=self.executable.parent, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        # Use bounded nonblocking writes, including when quit waits for another command.
        os.set_blocking(self.process.stdin.fileno(), False)
        threading.Thread(target=self.read_states, daemon=True).start()
        threading.Thread(target=self.drain_errors, daemon=True).start()

    def read_states(self):
        try:
            while True:
                line = self.process.stdout.readline(MAXIMUM_LINE + 1)
                if not line:
                    break
                if len(line) > MAXIMUM_LINE:
                    raise ValueError("Receiver state is too large")
                if not line.endswith(b"\n"):
                    raise ValueError("Receiver disconnected mid-frame")
                line = line.decode("utf-8", errors="strict")
                state = parse_state(line, expected_dry_run=self.dry_run)
                if not self.stopping:
                    self.on_state(state)
        except (OSError, UnicodeError, ValueError):
            pass
        finally:
            if not self.stopping:
                self.on_failure()
                try:
                    self.stop()
                except (OSError, ValueError, subprocess.TimeoutExpired):
                    pass  # The visible window retains a Quit button for a retry.

    def drain_errors(self):
        # Never copy diagnostics or private snapshots into a log or UI message.
        try:
            while self.process.stderr.read(2048):
                pass
        except (OSError, UnicodeError, ValueError):
            pass

    def send(self, command, deadline=None):
        if command not in {"refresh", "requestAccess", "quit"}:
            raise ValueError("Unknown UI command")
        if deadline is None:
            deadline = time.monotonic() + 5
        if not self.writer_lock.acquire(timeout=max(0, deadline - time.monotonic())):
            raise TimeoutError("Receiver command timed out")
        try:
            if self.process is None or self.process.poll() is not None:
                raise OSError("Receiver is not running")
            data = memoryview((json.dumps({"type": command}) + "\n").encode("utf-8"))
            descriptor = self.process.stdin.fileno()
            while data:
                if self.stopping and command != "quit":
                    raise OSError("Receiver is stopping")
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise TimeoutError("Receiver command timed out")
                try:
                    data = data[os.write(descriptor, data):]
                except BlockingIOError:
                    select.select([], [descriptor], [], remaining)
        finally:
            self.writer_lock.release()

    def stop(self):
        self.stopping = True
        deadline = time.monotonic() + SHUTDOWN_GRACE_SECONDS
        if not self.shutdown_lock.acquire(timeout=SHUTDOWN_GRACE_SECONDS):
            raise TimeoutError("Receiver shutdown is already in progress")
        try:
            self.stop_owned_process(deadline)
        finally:
            self.shutdown_lock.release()

    def stop_owned_process(self, deadline):
        if self.process is None:
            return
        if self.process.poll() is None:
            try:
                self.send("quit", deadline)
            except (OSError, ValueError):
                pass
            try:
                self.process.wait(timeout=max(0, deadline - time.monotonic()))
            except subprocess.TimeoutExpired:
                self.process.terminate()
                try:
                    self.process.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    self.process.kill()
                    self.process.wait(timeout=2)
        for stream in (self.process.stdin, self.process.stdout, self.process.stderr):
            stream.close()


def status_notifier_host_present():
    """True when a notification-area host (StatusNotifierWatcher) is on the session bus."""
    try:
        from gi.repository import Gio, GLib
        bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
        reply = bus.call_sync("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus",
                              "NameHasOwner", GLib.Variant("(s)", ("org.kde.StatusNotifierWatcher",)),
                              GLib.VariantType.new("(b)"), Gio.DBusCallFlags.NONE, 1000, None)
        return bool(reply.unpack()[0])
    except Exception:  # No session bus or D-Bus error: no host to show an indicator.
        return False


def create_indicator(Gtk, window):
    """A native notification-area menu where the desktop offers one (KDE, Xfce, Cinnamon,
    Ubuntu's GNOME). AppIndicator menus cannot show images, so the pairing code stays in
    the small window that 显示配对二维码 opens. Returns None when no indicator library exists."""
    try:
        import gi
        try:
            gi.require_version("AyatanaAppIndicator3", "0.1")
            from gi.repository import AyatanaAppIndicator3 as AppIndicator
        except (ImportError, ValueError):
            gi.require_version("AppIndicator3", "0.1")
            from gi.repository import AppIndicator3 as AppIndicator
    except (ImportError, ValueError):
        return None
    if not status_notifier_host_present():
        # Stock GNOME can have the bindings installed with nothing to display them; keep the
        # minimized-window fallback so the running receiver stays discoverable.
        return None
    indicator = AppIndicator.Indicator.new("sofatap-receiver", "input-mouse-symbolic",
                                           AppIndicator.IndicatorCategory.APPLICATION_STATUS)
    menu = Gtk.Menu()
    status = Gtk.MenuItem(label="正在准备配对")
    status.set_sensitive(False)
    items = [status, Gtk.SeparatorMenuItem()]
    for label, handler in (("显示配对二维码…", window.show_receiver), ("复制配对链接", window.copy_pairing),
                           ("刷新", window.refresh_state)):
        item = Gtk.MenuItem(label=label)
        item.connect("activate", handler)
        items.append(item)
    items.append(Gtk.SeparatorMenuItem())
    quit_item = Gtk.MenuItem(label="退出 Sofatap")
    quit_item.connect("activate", window.close_receiver)
    items.append(quit_item)
    for item in items:
        menu.append(item)
    menu.show_all()
    indicator.set_menu(menu)
    indicator.set_status(AppIndicator.IndicatorStatus.ACTIVE)
    indicator.set_title("Sofatap")
    window.tray_status = status
    window.tray_indicator = indicator
    status.set_label(window.status.get_text())
    return indicator


def create_window(Gtk, Gdk, GdkPixbuf, GLib, backend_factory, autostart=None, startup_error=None, updater=None):
    """Build the real native UI with an injectable owned backend for isolated previews."""
    from gi.repository import Pango
    provider = Gtk.CssProvider()
    provider.load_from_data(b"""
        #sofatap-receiver { background-color: #11191B; color: #F0F5F3; }
        #sofatap-receiver label { color: #F0F5F3; }
        #sofatap-receiver .headline { font-size: 28px; font-weight: 700; }
        #sofatap-receiver .muted { color: #A8BAB7; font-size: 13px; }
        #sofatap-receiver .status-pill { background: #1E2A2C; border: 1px solid #334346;
            border-radius: 18px; padding: 7px 13px; }
        #sofatap-receiver .status-label { font-size: 12px; }
        #sofatap-receiver .status-dot { color: #A8BAB7; font-size: 13px; }
        #sofatap-receiver .status-dot.ready { color: #98E9C4; }
        #sofatap-receiver .status-dot.attention { color: #E6C78A; }
        #sofatap-receiver .pairing-card { background: #1E2A2C; border: 1px solid #334346;
            border-radius: 18px; padding: 20px; }
        #sofatap-receiver .qr-surface { background: #FFFFFF; padding: 12px; border-radius: 10px; }
        #sofatap-receiver .qr-surface label { color: #334346; font-size: 12px; }
        #sofatap-receiver .machine { font-weight: 600; font-size: 14px; }
        #sofatap-receiver .endpoint button { background: #172124; color: #F0F5F3;
            border: 1px solid #334346; border-radius: 9px; box-shadow: none; padding: 8px 10px; }
        #sofatap-receiver .endpoint button:hover { background: #293A3D; }
        #sofatap-receiver .endpoint button:focus { outline: 2px solid #98E9C4; outline-offset: 2px; }
        #sofatap-receiver button { text-shadow: none; box-shadow: none; }
        #sofatap-receiver button.copy { background: #98E9C4; color: #11191B;
            border: 1px solid #98E9C4; border-radius: 11px; font-size: 15px; font-weight: 700;
            padding: 13px 16px; }
        #sofatap-receiver button.copy label { color: #11191B; }
        #sofatap-receiver button.copy:hover { background: #B5F3D8; }
        #sofatap-receiver button.copy:active { background: #7CD8AF; }
        #sofatap-receiver button.copy:disabled { background: #334346; border-color: #334346; }
        #sofatap-receiver button.copy:disabled label { color: #A8BAB7; }
        #sofatap-receiver button.copy:focus, #sofatap-receiver button.quiet:focus,
        #sofatap-receiver button.access:focus { outline: 2px solid #F0F5F3; outline-offset: 3px; }
        #sofatap-receiver button.quiet { background: transparent; border: 1px solid transparent;
            color: #A8BAB7; padding: 8px 14px; border-radius: 9px; }
        #sofatap-receiver button.quiet label { color: #A8BAB7; }
        #sofatap-receiver button.quiet:hover { background: #1E2A2C; border-color: #334346; }
        #sofatap-receiver button.quiet:disabled label { color: #70817F; }
        #sofatap-receiver button.access { background: #243734; border: 1px solid #98E9C4;
            border-radius: 10px; padding: 10px 14px; }
        #sofatap-receiver button.access label { color: #98E9C4; }
        #sofatap-receiver button.access:disabled { border-color: #334346; }
    """)

    def styled(widget, name):
        widget.get_style_context().add_class(name)
        return widget

    def text(label, style=None, align=.5):
        widget = Gtk.Label(label=label, xalign=align)
        widget.set_line_wrap(True)
        if style:
            styled(widget, style)
        return widget

    class Window(Gtk.Window):
        def __init__(self):
            super().__init__(title="Sofatap")
            self.set_name("sofatap-receiver")
            # Packaged builds and source previews share the approved iPhone artwork.
            # Set it directly as well as in the desktop entry for portable launches.
            root = Path(__file__).resolve().parents[2]
            icon = root / "sofatap.png"
            if not icon.is_file():
                icon = root / "ios/SofaTap/Assets.xcassets/AppIcon.appiconset/AppIcon.png"
            if icon.is_file():
                self.set_icon_from_file(str(icon))
            Gtk.StyleContext.add_provider_for_screen(self.get_screen(), provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)
            self.set_default_size(470, 700)
            self.set_position(Gtk.WindowPosition.CENTER)
            self.pairings = ()
            self.rendered_png = None
            self.updating = False
            self.stopping = False
            self.failed = False
            self.last_state_at = time.monotonic()
            self.copy_reset_source = None
            scroll = Gtk.ScrolledWindow()
            scroll.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
            self.add(scroll)
            layout = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12)
            layout.set_border_width(24)
            scroll.add(layout)
            status_box = styled(Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=7), "status-pill")
            status_box.set_halign(Gtk.Align.CENTER)
            self.status_dot = styled(Gtk.Label(label="●"), "status-dot")
            self.status = text("正在检查桌面…", "status-label")
            self.status.set_max_width_chars(28)
            status_box.pack_start(self.status_dot, False, False, 0)
            status_box.pack_start(self.status, False, False, 0)
            layout.pack_start(status_box, False, False, 0)
            title = text("扫码，坐回沙发", "headline")
            layout.pack_start(title, False, False, 0)
            helper = text("在 iPhone 上打开 Sofatap，扫描二维码", "muted")
            layout.pack_start(helper, False, False, 0)
            card = styled(Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=18), "pairing-card")
            layout.pack_start(card, False, False, 0)
            qr_surface = styled(Gtk.Box(orientation=Gtk.Orientation.VERTICAL), "qr-surface")
            qr_surface.set_halign(Gtk.Align.CENTER)
            self.qr_stack = Gtk.Stack()
            self.image = Gtk.Image()
            self.image.set_size_request(224, 224)
            self.qr_placeholder = text("正在准备二维码…")
            self.qr_placeholder.set_size_request(224, 224)
            self.qr_stack.add_named(self.image, "qr")
            self.qr_stack.add_named(self.qr_placeholder, "placeholder")
            self.qr_stack.set_visible_child_name("placeholder")
            qr_surface.pack_start(self.qr_stack, False, False, 0)
            card.pack_start(qr_surface, False, False, 0)
            identity = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=12)
            machine_row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
            machine_row.pack_start(Gtk.Image.new_from_icon_name("computer-symbolic", Gtk.IconSize.MENU), False, False, 0)
            self.name = text("正在启动接收器…", "machine", align=0)
            self.name.set_line_wrap(False)
            self.name.set_ellipsize(Pango.EllipsizeMode.END)
            self.name.set_max_width_chars(16)
            machine_row.pack_start(self.name, True, True, 0)
            identity.pack_start(machine_row, True, True, 0)
            self.addresses = Gtk.ComboBoxText()
            for renderer in self.addresses.get_cells():
                renderer.set_property("ellipsize", Pango.EllipsizeMode.END)
                renderer.set_property("max-width-chars", 16)
            styled(self.addresses, "endpoint")
            self.addresses.set_tooltip_text("选择这台电脑可供 iPhone 连接的实际地址")
            self.addresses.get_accessible().set_name("电脑连接地址")
            self.addresses.connect("changed", self.render_qr)
            identity.pack_end(self.addresses, False, False, 0)
            card.pack_start(identity, False, False, 0)
            self.copy_button = styled(Gtk.Button(label="复制配对链接"), "copy")
            self.copy_button.set_sensitive(False)
            self.copy_button.set_tooltip_text("仅复制当前地址的配对链接。链接包含控制凭据，请勿分享。")
            self.copy_button.connect("clicked", self.copy_pairing)
            card.pack_start(self.copy_button, False, False, 0)
            self.status_detail = text("", "muted")
            self.status_detail.set_no_show_all(True)
            layout.pack_start(self.status_detail, False, False, 0)
            self.access_button = styled(Gtk.Button(label="允许控制桌面"), "access")
            self.access_button.set_sensitive(False)
            self.access_button.set_no_show_all(True)
            self.access_button.connect("clicked", self.request_access)
            layout.pack_start(self.access_button, False, False, 0)
            footer = text("iPhone 与电脑连接同一网络\n配对码和链接包含控制凭据，请勿分享", "muted")
            footer.set_justify(Gtk.Justification.CENTER)
            layout.pack_start(footer, False, False, 0)
            self.updater = updater
            self.update_busy = False
            self.update_restart = False
            self.phone_connected = False
            self.autostart = autostart
            startup_message = startup_error
            self.startup_toggle = Gtk.CheckButton(label="登录后自动启动")
            self.startup_toggle.set_halign(Gtk.Align.CENTER)
            self.startup_toggle.set_sensitive(autostart is not None)
            try:
                self.startup_toggle.set_active(autostart.enabled() if autostart is not None else False)
            except OSError:
                startup_message = "无法读取启动设置"
            self.startup_toggle.set_tooltip_text("默认开启；关闭窗口会最小化，选择退出才停止接收")
            self.startup_toggle.connect("toggled", self.change_autostart)
            layout.pack_start(self.startup_toggle, False, False, 0)
            self.startup_detail = text(startup_message or "", "muted")
            self.startup_detail.set_no_show_all(True)
            layout.pack_start(self.startup_detail, False, False, 0)
            self.startup_detail.set_visible(bool(startup_message))
            self.update_toggle = Gtk.CheckButton(label="自动检查并下载更新")
            self.update_toggle.set_halign(Gtk.Align.CENTER)
            self.update_toggle.set_sensitive(updater is not None)
            try:
                self.update_toggle.set_active(updater.preferences()["automatic"] if updater else False)
            except (OSError, ValueError):
                self.update_toggle.set_active(False)
            self.update_toggle.connect("toggled", self.change_updates)
            layout.pack_start(self.update_toggle, False, False, 0)
            update_buttons = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
            update_buttons.set_halign(Gtk.Align.CENTER)
            self.update_check = styled(Gtk.Button(label="检查更新"), "quiet")
            self.update_check.set_sensitive(updater is not None)
            self.update_check.connect("clicked", lambda *_: self.check_updates(True))
            self.update_install = styled(Gtk.Button(label="更新并重启"), "quiet")
            self.update_install.set_sensitive(False)
            self.update_install.connect("clicked", self.install_update)
            update_buttons.pack_start(self.update_check, False, False, 0)
            update_buttons.pack_start(self.update_install, False, False, 0)
            layout.pack_start(update_buttons, False, False, 0)
            self.update_detail = text("", "muted")
            layout.pack_start(self.update_detail, False, False, 0)
            buttons = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=12)
            buttons.set_halign(Gtk.Align.CENTER)
            self.refresh = styled(Gtk.Button(label="刷新"), "quiet")
            self.refresh.set_image(Gtk.Image.new_from_icon_name("view-refresh-symbolic", Gtk.IconSize.MENU))
            self.refresh.set_always_show_image(True)
            self.refresh.set_sensitive(False)
            self.refresh.connect("clicked", self.refresh_state)
            self.quit_button = styled(Gtk.Button(label="退出"), "quiet")
            self.quit_button.set_image(Gtk.Image.new_from_icon_name("system-shutdown-symbolic", Gtk.IconSize.MENU))
            self.quit_button.set_always_show_image(True)
            self.quit_button.get_accessible().set_name("退出 Sofatap 接收器")
            self.quit_button.connect("clicked", self.close_receiver)
            buttons.pack_start(self.refresh, False, False, 0)
            buttons.pack_start(self.quit_button, False, False, 0)
            layout.pack_start(buttons, False, False, 0)
            self.connect("delete-event", self.close_window)
            self.backend = backend_factory(
                lambda state: GLib.idle_add(self.apply_state, state),
                lambda: GLib.idle_add(self.show_failure))
            self.show_all()
            GLib.timeout_add_seconds(1, self.check_state_deadline)
            if self.updater is not None:
                GLib.timeout_add_seconds(10, lambda: self.check_updates(False))
                GLib.timeout_add_seconds(3600, self.periodic_update)
            try:
                self.backend.start()
            except OSError:
                self.show_failure()

        def change_updates(self, toggle):
            if self.updater is None:
                return
            try:
                self.updater.set_automatic(toggle.get_active())
            except (OSError, ValueError):
                toggle.handler_block_by_func(self.change_updates)
                toggle.set_active(not toggle.get_active())
                toggle.handler_unblock_by_func(self.change_updates)
                self.update_detail.set_text("无法保存更新设置，请检查文件权限")

        def periodic_update(self):
            if self.stopping:
                return False
            self.check_updates(False)
            return True

        def check_updates(self, manual=False):
            if self.updater is None or self.update_busy or self.stopping:
                return False
            self.update_busy = True
            self.update_check.set_sensitive(False)
            if manual:
                self.update_detail.set_text("正在检查更新…")
            def work():
                try:
                    message = self.updater.check(manual)
                except Exception:
                    message = "暂时无法检查或验证更新，请稍后重试"
                GLib.idle_add(self.update_finished, message)
            threading.Thread(target=work, daemon=True).start()
            return False

        def update_finished(self, message):
            self.update_busy = False
            if self.stopping:
                return False
            self.update_check.set_sensitive(True)
            if message:
                self.update_detail.set_text(message)
            self.update_install.set_sensitive(bool(self.updater.pending()) and not self.phone_connected)
            return False

        def install_update(self, *_):
            if self.updater is not None and not self.phone_connected and not self.update_busy:
                self.update_restart = True
                self.close_receiver()

        def change_autostart(self, toggle):
            if self.autostart is None:
                return
            try:
                self.autostart.set_enabled(toggle.get_active())
                self.startup_detail.set_visible(False)
            except (OSError, ValueError):
                toggle.handler_block_by_func(self.change_autostart)
                try:
                    toggle.set_active(self.autostart.enabled())
                except OSError:
                    toggle.set_active(False)
                finally:
                    toggle.handler_unblock_by_func(self.change_autostart)
                self.startup_detail.set_text("无法保存启动设置，请检查此账户的文件权限")
                self.startup_detail.show()

        def close_window(self, *_):
            if self.autostart is None or self.failed:
                return self.close_receiver()
            if getattr(self, "tray_status", None) is not None:
                # With a notification-area indicator the window steps back to it.
                self.hide()
                return True
            # Without one (stock GNOME), remain discoverable in the task switcher.
            # Explicit Quit still closes the owned backend.
            self.iconify()
            return True

        def show_receiver(self, *_):
            self.show()
            self.deiconify()
            self.present()

        def apply_state(self, state):
            if self.stopping or self.failed:
                return False
            self.last_state_at = time.monotonic()
            self.phone_connected = state.connected
            if self.updater is not None:
                self.update_install.set_sensitive(bool(self.updater.pending()) and not state.connected and not self.update_busy)
                self.update_install.set_tooltip_text("请先断开手机连接" if state.connected else "保留配对和设置，重启接收器")
            self.name.set_text(state.name)
            self.name.set_tooltip_text(state.name)
            self.name.get_accessible().set_name(state.name)
            if state.input_status == "ready" and not state.pairings:
                self.set_status("暂无可用网络地址", "attention", "连接 Wi-Fi 或网线后刷新，重新获取配对地址。")
            elif state.input_status == "ready":
                self.set_status("桌面已就绪 · " + ("iPhone 已连接" if state.connected else "等待 iPhone"), "ready")
            elif state.dry_run:
                self.set_status(STATUS_LABELS["dry_run"])
            else:
                summary = {"permission_required": "需要桌面控制权限", "permission_pending": "等待系统授权",
                           "permission_denied": "桌面控制尚未授权", "desktop_unavailable": "桌面暂不可用",
                           "unsupported_session": "当前桌面暂不支持", "dependency_missing": "需要安装桌面组件",
                           "input_unavailable": "桌面控制已中断"}[state.input_status]
                detail = STATUS_LABELS[state.input_status]
                if state.connected:
                    detail = "iPhone 已连接 · " + detail
                self.set_status(summary, "attention", detail)
            can_request = not state.dry_run and state.input_status in ACCESS_STATUSES
            self.access_button.set_visible(can_request or state.input_status == "permission_pending")
            self.access_button.set_sensitive(can_request)
            selected = self.addresses.get_active_text()
            self.updating = True
            self.pairings = state.pairings
            self.addresses.remove_all()
            for pairing in self.pairings:
                self.addresses.append_text(pairing.host)
            index = next((i for i, pairing in enumerate(self.pairings) if pairing.host == selected), 0)
            self.addresses.set_active(index if self.pairings else -1)
            self.updating = False
            self.refresh.set_sensitive(True)
            self.render_qr()
            return False

        def render_qr(self, *_):
            if self.updating:
                return
            self.reset_copy_label()
            index = self.addresses.get_active()
            if index < 0 or index >= len(self.pairings):
                self.image.clear()
                self.rendered_png = None
                self.copy_button.set_sensitive(False)
                self.qr_placeholder.set_text("暂无可用连接地址")
                self.qr_stack.set_visible_child_name("placeholder")
                self.addresses.set_tooltip_text("暂无可用连接地址")
                return
            self.addresses.set_tooltip_text(self.pairings[index].host + "\n选择这台电脑可供 iPhone 连接的实际地址")
            self.copy_button.set_sensitive(bool(self.pairings[index].uri) and not self.failed and not self.stopping)
            png = self.pairings[index].png
            if png == self.rendered_png:
                return
            try:
                loader = GdkPixbuf.PixbufLoader.new_with_type("png")
                loader.write(png)
                loader.close()
                pixbuf = loader.get_pixbuf()
                scale = min(224 / pixbuf.get_width(), 224 / pixbuf.get_height())
                pixbuf = pixbuf.scale_simple(max(1, int(pixbuf.get_width() * scale)), max(1, int(pixbuf.get_height() * scale)), GdkPixbuf.InterpType.NEAREST)
                self.image.set_from_pixbuf(pixbuf)
                self.rendered_png = png
                self.qr_stack.set_visible_child_name("qr")
            except GLib.Error:
                self.image.clear()
                self.rendered_png = None
                self.copy_button.set_sensitive(False)
                self.qr_placeholder.set_text("二维码暂时不可用")
                self.qr_stack.set_visible_child_name("placeholder")
                self.set_status("二维码暂时不可用", "attention", "请刷新；若仍不可用，请重新打开接收器。")

        def set_status(self, message, kind=None, detail=""):
            self.status.set_text(message)
            if getattr(self, "tray_status", None) is not None:
                self.tray_status.set_label(message)
            context = self.status_dot.get_style_context()
            for name in ("ready", "attention"):
                context.remove_class(name)
            if kind:
                context.add_class(kind)
            self.status_detail.set_text(detail)
            self.status_detail.set_visible(bool(detail))

        def reset_copy_label(self):
            if self.copy_reset_source is not None:
                GLib.source_remove(self.copy_reset_source)
                self.copy_reset_source = None
            self.copy_button.set_label("复制配对链接")
            return False

        def copy_pairing(self, *_):
            # The only clipboard access in this UI: an explicit user action.
            # No clipboard read, auto-copy, persistence request or secret logging.
            index = self.addresses.get_active()
            if self.failed or self.stopping or not 0 <= index < len(self.pairings):
                return
            uri = self.pairings[index].uri
            if uri is None:
                return
            clipboard = Gtk.Clipboard.get(Gdk.SELECTION_CLIPBOARD)
            clipboard.set_text(uri, -1)
            self.reset_copy_label()
            self.copy_button.set_label("已复制")
            def reset():
                self.copy_reset_source = None
                self.copy_button.set_label("复制配对链接")
                return False
            self.copy_reset_source = GLib.timeout_add_seconds(2, reset)

        def check_state_deadline(self):
            if self.stopping or self.failed:
                return False
            if time.monotonic() - self.last_state_at > STATE_DEADLINE_SECONDS:
                self.show_failure()
                return False
            return True

        def request_access(self, *_):
            # Only this explicit button click may trigger a native portal dialog.
            self.access_button.set_sensitive(False)
            self.send_command("requestAccess")

        def refresh_state(self, *_):
            self.send_command("refresh")

        def send_command(self, command):
            def send():
                try:
                    self.backend.send(command)
                except (OSError, ValueError):
                    GLib.idle_add(self.show_failure)
            threading.Thread(target=send, daemon=True).start()

        def show_failure(self):
            if not self.stopping and not self.failed:
                self.failed = True
                self.image.clear()
                self.rendered_png = None
                self.pairings = ()
                self.addresses.remove_all()
                self.addresses.set_sensitive(False)
                self.copy_button.set_sensitive(False)
                self.qr_placeholder.set_text("连接已中断")
                self.qr_stack.set_visible_child_name("placeholder")
                self.refresh.set_sensitive(False)
                self.access_button.set_sensitive(False)
                self.set_status("接收器连接已中断", "attention", "请检查后端版本，退出后重试。")
                if not self.backend.stopping:
                    def stop_failed_backend():
                        try:
                            self.backend.stop()
                        except (OSError, ValueError, subprocess.TimeoutExpired):
                            pass  # The visible Quit button remains available for retry.
                    threading.Thread(target=stop_failed_backend, daemon=True).start()
            return False

        def close_receiver(self, *_):
            if self.stopping:
                return True
            self.stopping = True
            self.image.clear()
            self.pairings = ()
            self.rendered_png = None
            self.addresses.set_sensitive(False)
            self.copy_button.set_sensitive(False)
            self.reset_copy_label()
            self.qr_placeholder.set_text("正在退出…")
            self.qr_stack.set_visible_child_name("placeholder")
            self.set_status("正在退出接收器…")
            self.refresh.set_sensitive(False)
            self.access_button.set_sensitive(False)
            self.quit_button.set_sensitive(False)
            def stop():
                try:
                    self.backend.stop()
                except (OSError, ValueError, subprocess.TimeoutExpired):
                    GLib.idle_add(self.show_shutdown_failure)
                else:
                    GLib.idle_add(self.finish_close)
            threading.Thread(target=stop, daemon=True).start()
            return True

        def show_shutdown_failure(self):
            self.stopping = False
            self.quit_button.set_sensitive(True)
            self.set_status("接收进程尚未退出", "attention", "请重试退出，或在系统进程管理器中关闭接收端。")
            return False

        def finish_close(self):
            self.reset_copy_label()
            self.destroy()
            Gtk.main_quit()
            return False

    return Window()


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--backend", required=True, type=Path, help="self-contained Sofatap receiver executable")
    parser.add_argument("--dry-run", action="store_true", help="preview pairing without sending mouse or keyboard events")
    parser.add_argument("--startup", action="store_true", help="start minimized after desktop login")
    args = parser.parse_args(argv)
    if sys.platform != "linux":
        parser.error("the Linux receiver requires Linux; protocol checks can run on other systems")
    executable = args.backend.expanduser().resolve()
    if not executable.is_file() or not os.access(executable, os.X_OK):
        parser.error("--backend must point to an executable Sofatap receiver")
    try:
        import gi
        gi.require_version("Gtk", "3.0")
        from gi.repository import Gdk, GdkPixbuf, GLib, Gtk
    except (ImportError, ValueError):
        print("Sofatap requires Python 3, PyGObject and GTK 3. See the included README.md.", file=sys.stderr)
        return 2
    if not Gtk.init_check()[0]:
        print("Sofatap requires a logged-in graphical Linux desktop.", file=sys.stderr)
        return 2

    from autostart import Autostart
    from receiver_instance import ReceiverInstance
    instance = None
    startup = None
    startup_error = None
    updater = None
    if not args.dry_run:
        try:
            instance = ReceiverInstance()
            if not instance.acquire(startup=args.startup):
                return 0
        except OSError:
            print("Sofatap could not safely open its private receiver session.", file=sys.stderr)
            return 2
        from receiver_update import ReceiverUpdater
        try:
            updater = ReceiverUpdater(executable.parent.parent)
            if updater.apply_pending():
                instance.close()
                os.execv(sys.executable, [sys.executable, "-E", "-s", "-B", str(Path(__file__).resolve()), *sys.argv[1:]])
        except (OSError, ValueError, KeyError, subprocess.TimeoutExpired, SyntaxError):
            startup_error = "自动更新未完成，继续使用当前版本；可通过检查更新重试"
        startup = Autostart([sys.executable, "-E", "-s", "-B", str(Path(__file__).resolve()),
                             "--backend", str(executable), "--startup"])
        try:
            startup.initialize()
        except (OSError, ValueError):
            startup_error = "无法设置登录后自动启动，可稍后重试"
    window = None
    try:
        window = create_window(Gtk, Gdk, GdkPixbuf, GLib,
            lambda on_state, on_failure: Backend(executable, on_state, on_failure, dry_run=args.dry_run),
            autostart=startup, startup_error=startup_error, updater=updater)
        indicator = None if args.dry_run else create_indicator(Gtk, window)
        if args.startup:
            if indicator is not None:
                window.hide()
            else:
                window.iconify()
        if instance is not None:
            def check_activation():
                if window.stopping:
                    return False
                if instance.show_requested():
                    window.deiconify()
                    window.present()
                return True
            GLib.timeout_add(100, check_activation)
        Gtk.main()
        if window.update_restart and updater is not None:
            try:
                updater.apply_pending(explicit=True)
            except (OSError, ValueError, subprocess.TimeoutExpired, SyntaxError):
                print("Sofatap update could not be installed; the previous package is retained.", file=sys.stderr)
    finally:
        if window is not None:
            window.backend.stop()
        if instance is not None:
            instance.close()
    if window is not None and window.update_restart:
        os.execv(sys.executable, [sys.executable, "-E", "-s", "-B", str(Path(__file__).resolve()), *sys.argv[1:]])
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
