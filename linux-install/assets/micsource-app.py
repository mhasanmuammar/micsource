#!/usr/bin/env python3
"""
MicSource desktop control window (GTK 4 + libadwaita).

Launched from the app drawer (via the micsource-gui wrapper), the CLI
(`micsource window`), or the GNOME top-bar tile's "Open Control Window".

The main window shows device + monitoring status (the Monitoring row
carries a real-time input level bar fed by the background service's
metering — no extra capture stream), and the same actions as the
micsource CLI:

  * Start / Stop the background service (the only audio pump)
  * Install the staged APK on the device
  * Open the config folder
  * Build the APK from source

The header menu opens a Preferences dialog (Adw.PreferencesDialog when
libadwaita >= 1.5 is available, Adw.PreferencesWindow otherwise) with
instant-apply switches per the GNOME HIG:

  * Auto-start service at login        (systemd user unit enable/disable)
  * GNOME top-bar tile                 (gnome-extensions enable/disable)
  * Tray icon (AppIndicator, opt-in)   (XDG autostart entry + spawn/kill —
    legacy tray for KDE/XFCE/etc.; GNOME users should use the tile)
  * Virtual microphone / play to       (~/.config/micsource/config.ini;
    speakers                            applied on next service start)

Also sends desktop notifications on state changes (device link, install
results, service state). The tray icon stays on Gtk 3 because the
AppIndicator/Ayatana client bindings are Gtk 3 only.
"""
import configparser
import os
import re
import shutil
import socket
import subprocess
import sys
import threading
import time

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
from gi.repository import Adw, Gio, GLib, Gtk  # noqa: E402

APP_TITLE = "MicSource"
SYSTEMD_UNIT = "micsource.service"
EXT_ID = "micsource-tile@micsource.local"
DATA_DIR = os.path.expanduser("~/.local/share/micsource")
CONFIG_DIR = os.path.expanduser("~/.config/micsource")
CONFIG_PATH = os.path.join(CONFIG_DIR, "config.ini")
ADB_PATH_FILE = os.path.join(DATA_DIR, "adb.path")
CLI_PATH = os.path.join(DATA_DIR, "micsource")
BUILD_PATH = os.path.join(DATA_DIR, "micsource-build")
TRAY_PATH = os.path.join(DATA_DIR, "micsource-tray.py")
TRAY_DESKTOP = os.path.expanduser("~/.config/autostart/micsource-tray.desktop")
UNIT_FILE = os.path.expanduser(f"~/.config/systemd/user/{SYSTEMD_UNIT}")

ANDROID_PKG = "fr.dzx.audiosource"  # Android package (baked into the APK)
DEVICE_SOCKET = "audiosource"       # device-side socket (RecordThread)
DEFAULT_HOST_SOCKET = "micsource"   # host side of the adb forward

last_notified = None

ADB_CMD = "adb"
SERIAL = None
HOST_SOCKET = DEFAULT_HOST_SOCKET


def _log(msg):
    print(f"[micsource-app] {msg}", flush=True)


def _load_config():
    global ADB_CMD, SERIAL, HOST_SOCKET
    adb_path = ""
    serial = ""
    host_socket = ""
    parser = configparser.ConfigParser()
    try:
        parser.read(CONFIG_PATH)
        adb_path = parser.get("adb", "adb_path", fallback="").strip()
        serial = parser.get("device", "serial", fallback="").strip()
        host_socket = parser.get("socket", "host_socket_name", fallback="").strip()
    except Exception:
        pass
    if not adb_path:
        try:
            with open(ADB_PATH_FILE) as fh:
                adb_path = fh.read().strip()
        except OSError:
            adb_path = ""
    ADB_CMD = adb_path or "adb"
    SERIAL = serial or None
    HOST_SOCKET = host_socket or DEFAULT_HOST_SOCKET


def _cfg_bool(section, key, default):
    parser = configparser.ConfigParser()
    try:
        parser.read(CONFIG_PATH)
        return parser.getboolean(section, key, fallback=default)
    except Exception:
        return default


def _cfg_set_bool(section, key, value):
    parser = configparser.ConfigParser()
    try:
        parser.read(CONFIG_PATH)
    except Exception:
        pass
    if not parser.has_section(section):
        parser.add_section(section)
    parser.set(section, key, "true" if value else "false")
    os.makedirs(os.path.dirname(CONFIG_PATH), exist_ok=True)
    with open(CONFIG_PATH, "w") as fh:
        parser.write(fh)
    return True


def _run_cmd(args, timeout=10):
    """Run a command; return (rc, combined output). Never raises."""
    try:
        proc = subprocess.run(args, capture_output=True, text=True, timeout=timeout)
        return proc.returncode, ((proc.stdout or "") + (proc.stderr or "")).strip()
    except FileNotFoundError:
        return 127, "command not found"
    except subprocess.TimeoutExpired:
        return 124, "timed out"
    except Exception as exc:  # noqa: BLE001
        return 1, str(exc)


def run_adb(args, timeout=5):
    """Run adb; return (rc, stdout, stderr). Never raises."""
    cmd = [ADB_CMD]
    if SERIAL:
        cmd += ["-s", SERIAL]
    cmd += list(args)
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return proc.returncode, proc.stdout, proc.stderr
    except FileNotFoundError:
        return 127, "", f"adb not found: {ADB_CMD}"
    except subprocess.TimeoutExpired:
        return 124, "", "adb timed out"
    except OSError as exc:
        return 1, "", str(exc)


def device_online():
    rc, out, _err = run_adb(["get-state"], timeout=3)
    return rc == 0 and out.strip() == "device"


def socket_forwarded():
    rc, out, _err = run_adb(["forward", "--list"], timeout=3)
    return rc == 0 and (f"localabstract:{HOST_SOCKET}" in out)


def ensure_forward():
    run_adb(["forward", "--remove", f"localabstract:{HOST_SOCKET}"], timeout=3)
    rc, _out, err = run_adb(
        ["forward", f"localabstract:{HOST_SOCKET}", f"localabstract:{DEVICE_SOCKET}"],
        timeout=5,
    )
    return rc == 0, err


def start_device_service():
    run_adb(["shell", "am", "force-stop", ANDROID_PKG], timeout=8)
    rc, _out, err = run_adb(
        ["shell", "am", "start", f"{ANDROID_PKG}/.MainActivity"], timeout=8
    )
    return rc == 0, err


def _make_switch_row(title, subtitle):
    """Build a HIG switch row; return (row, watch, get_active, set_active).

    Prefers Adw.SwitchRow (libadwaita >= 1.4) and falls back to an
    Adw.ActionRow with an embedded Gtk.Switch on older stacks. `watch` is
    the actor that owns the `active` property (the row itself for
    SwitchRow, the Gtk.Switch for the fallback) — used to connect
    notify::active.
    """
    if hasattr(Adw, "SwitchRow"):
        row = Adw.SwitchRow(title=title, subtitle=subtitle)
        return row, row, row.get_active, row.set_active
    row = Adw.ActionRow(title=title, subtitle=subtitle)
    sw = Gtk.Switch(valign=Gtk.Align.CENTER)
    row.add_suffix(sw)
    row.set_activatable_widget(sw)
    return row, sw, sw.get_active, sw.set_active


class MicSourceApp(Adw.Application):
    """Control window (Adwaita): status, service, install, build, prefs."""

    def __init__(self):
        super().__init__(application_id="local.micsource")
        # NON_UNIQUE: each launch is its own primary instance. The default
        # (unique) behavior hands activation off to whatever stale or
        # crashed instance still holds the bus name -- and the new process
        # exits silently without ever showing a window.
        self.set_flags(Gio.ApplicationFlags.NON_UNIQUE)
        self.window = None
        self.row_device = None
        self.row_monitor = None
        self.row_error = None
        self.log_view = None
        self.log_buffer = None
        self.btn_service_start = None
        self.btn_service_stop = None
        self.btn_install = None
        self.btn_build = None
        self._pref = None          # open preferences dialog/window (toasts)
        self.meter = None          # input level bar (Monitoring row suffix)
        self._meter_value = 0.0    # last level reported by the service
        self._meter_on = False     # meter polling thread flag

        act = Gio.SimpleAction.new("preferences", None)
        act.connect("activate", self._on_preferences_action)
        self.add_action(act)
        act = Gio.SimpleAction.new("about", None)
        act.connect("activate", self._on_about_action)
        self.add_action(act)

    # ------------------------------------------------------------------
    # UI construction (libadwaita)
    # ------------------------------------------------------------------
    def do_activate(self):
        self.window = Adw.ApplicationWindow(application=self)
        # Adaptive sizing: the content scroll page below keeps the window
        # usable at any height (GNOME HIG); 420x540 is just the default.
        self.window.set_default_size(420, 540)

        # Header bar (standard Adwaita window layout) + primary menu.
        header = Adw.HeaderBar(
            title_widget=Adw.WindowTitle(title="MicSource",
                                         subtitle="phone mic over USB"))
        menu_btn = Gtk.MenuButton()
        menu_btn.set_icon_name("open-menu-symbolic")
        menu_btn.set_tooltip_text("Menu")
        menu_model = Gio.Menu()
        menu_model.append("Preferences…", "app.preferences")
        menu_model.append("About MicSource", "app.about")
        menu_btn.set_menu_model(menu_model)
        header.pack_end(menu_btn)

        content = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12)
        content.set_margin_top(12)
        content.set_margin_bottom(12)
        content.set_margin_start(12)
        content.set_margin_end(12)

        # ---- status group (Settings-style property rows) -----------------
        status_group = Adw.PreferencesGroup(title="Status")
        content.append(status_group)

        self.row_device = Adw.ActionRow(title="Device", subtitle="checking…")
        self.row_device.add_css_class("property")
        status_group.add(self.row_device)

        self.row_monitor = Adw.ActionRow(title="Monitoring",
                                         subtitle="checking…")
        self.row_monitor.add_css_class("property")
        status_group.add(self.row_monitor)

        # Input level bar in the row itself (HIG property row with suffix):
        # answers "is the phone sending audio?" right where you read the
        # status instead of a separate decorative block.
        self.meter = Gtk.ProgressBar()
        self.meter.set_size_request(240, -1)
        self.meter.set_valign(Gtk.Align.CENTER)
        self.row_monitor.add_suffix(self.meter)

        self.row_error = Adw.ActionRow(title="Error", subtitle="")
        self.row_error.add_css_class("error")
        self.row_error.set_visible(False)
        status_group.add(self.row_error)

        # ---- service controls (level pair of equal-width buttons) --------
        svc_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
        svc_box.set_homogeneous(True)
        self.btn_service_start = Gtk.Button(label="Start Service")
        self.btn_service_start.add_css_class("suggested-action")
        self.btn_service_start.connect("clicked", self.on_service_start)
        self.btn_service_stop = Gtk.Button(label="Stop Service")
        self.btn_service_stop.add_css_class("destructive-action")
        self.btn_service_stop.connect("clicked", self.on_service_stop)
        svc_box.append(self.btn_service_start)
        svc_box.append(self.btn_service_stop)
        content.append(svc_box)

        # ---- device utilities (boxed list with flat row buttons) ---------
        util_group = Adw.PreferencesGroup(title="Device")
        self._action_row_button(
            util_group, "Install APK on the Phone",
            "Installs the staged APK and restores the socket forward",
            "Install", self.on_install_apk)
        self._action_row_button(
            util_group, "Build APK from Source",
            "Compiles the project checkout (first run is slow)",
            "Build", self.on_build_apk)
        self._action_row_button(
            util_group, "Open Config Folder", "", "Open", self.on_open_config)
        content.append(util_group)

        # ---- activity log --------------------------------------------------
        self.log_view = Gtk.TextView()
        self.log_view.set_editable(False)
        self.log_view.set_cursor_visible(False)
        self.log_view.set_wrap_mode(Gtk.WrapMode.NONE)
        self.log_buffer = self.log_view.get_buffer()

        scroll = Gtk.ScrolledWindow()
        scroll.set_policy(Gtk.PolicyType.AUTOMATIC, Gtk.PolicyType.AUTOMATIC)
        scroll.set_size_request(-1, 110)
        scroll.set_child(self.log_view)

        content.append(Gtk.Label(label="Activity log", xalign=0,
                                 halign=Gtk.Align.START))
        content.append(Gtk.Frame(child=scroll))

        # Adaptive page: clamped width (HIG single-column layout like
        # gnome-settings) inside a vertical scroll, so the window works
        # at any height instead of overflowing a fixed size.
        clamp = Adw.Clamp(maximum_size=600, tightening_threshold=500)
        clamp.set_child(content)
        page_scroll = Gtk.ScrolledWindow()
        page_scroll.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        page_scroll.set_child(clamp)

        viewer = Adw.ToolbarView()
        viewer.add_top_bar(header)
        viewer.set_content(page_scroll)
        self.window.set_content(viewer)

        self.window.connect("close-request", self._on_close_request)
        self._meter_on = True
        threading.Thread(target=self._meter_loop, daemon=True).start()

        self.window.present()
        self.log_line("MicSource control window opened.")
        GLib.timeout_add_seconds(3, self._refresh)
        self._refresh()

    def _button(self, grid, col, row, label, handler):
        btn = Gtk.Button(label=label)
        btn.set_hexpand(True)
        btn.connect("clicked", handler)
        grid.attach(btn, col, row, 1, 1)
        return btn

    def _action_row_button(self, group, title, subtitle, label, handler):
        """HIG boxed-list row: title/subtitle with a flat button suffix.

        The row background activates the same handler (single control per
        row; the button remains visible for pointer users).
        """
        btn = Gtk.Button(label=label, valign=Gtk.Align.CENTER)
        btn.add_css_class("flat")
        if handler in (self.on_install_apk, self.on_build_apk):
            # keep the existing reference for enable/disable during work
            if handler is self.on_install_apk:
                self.btn_install = btn
            else:
                self.btn_build = btn
        btn.connect("clicked", handler)
        row = Adw.ActionRow(title=title, subtitle=subtitle)
        row.add_suffix(btn)
        row.set_activatable_widget(btn)
        group.add(row)

    # ------------------------------------------------------------------
    # Input level bar (fed by the service; no capture stream)
    # ------------------------------------------------------------------
    def _on_close_request(self, *_args):
        self._meter_on = False
        return False  # still close the window

    def _meter_loop(self):
        """Poll the service's `level` metric for the level bar."""
        while self._meter_on:
            val = 0.0
            s = None
            try:
                s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                s.settimeout(1.2)
                s.connect(os.path.join(DATA_DIR, "micsource.sock"))
                s.sendall(b"level")
                resp = s.recv(16).decode(errors="ignore").strip()
                val = float(resp) if resp else 0.0
            except Exception:
                val = 0.0
            finally:
                if s is not None:
                    try:
                        s.close()
                    except OSError:
                        pass
            GLib.idle_add(self._meter_draw_value, val)
            time.sleep(0.3)

    def _meter_draw_value(self, val):
        self._meter_value = max(0.0, min(1.0, val))
        if self.meter is not None:
            self.meter.set_fraction(self._meter_value)
        return False

    # ------------------------------------------------------------------
    # Helpers (main-thread only)
    # ------------------------------------------------------------------
    def log_line(self, line):
        self.log_buffer.insert(self.log_buffer.get_end_iter(), line.rstrip() + "\n")
        self.log_view.scroll_mark_onscreen(self.log_buffer.get_insert())

    def _toast(self, msg):
        """Show a toast in the preferences dialog (or log as fallback)."""
        if self._pref is not None:
            try:
                self._pref.add_toast(Adw.Toast.new(msg))
                return
            except Exception:
                pass
        self.log_line(msg)

    def _service_state(self):
        try:
            proc = subprocess.run(
                ["systemctl", "--user", "is-active", SYSTEMD_UNIT],
                capture_output=True, text=True, timeout=4)
            return (proc.stdout or "").strip() or "unknown"
        except Exception:
            return "unknown"

    def _notify(self, title, body, icon="dialog-information"):
        try:
            notif = Gio.Notification.new(title)
            notif.set_body(body)
            notif.set_icon(Gio.ThemedIcon.new(icon))
            self.send_notification(None, notif)
            return
        except Exception:
            pass  # fall back to libnotify
        try:
            subprocess.run(["notify-send", "-i", icon, title, body],
                           check=False, timeout=5)
        except Exception:
            pass  # notifications are best-effort

    def _error_dialog(self, title, text):
        """Adw.MessageDialog (GTK4 replaced Gtk.MessageDialog.run)."""
        dlg = Adw.MessageDialog.new(self.window, title, text)
        dlg.add_response("close", "Close")
        dlg.set_close_response("close")
        dlg.present()

    # ------------------------------------------------------------------
    # Periodic status refresh (3 s)
    # ------------------------------------------------------------------
    def _refresh(self):
        def worker():
            try:
                online = device_online()
                forwarded = socket_forwarded() if online else False
                service = self._service_state()
                monitor = self._query_monitor()
                # Device model name: prefer the monitor's already-resolved
                # name — its probe chain (ro.product.marketname -> model ->
                # ...) yields user-facing marketing names such as "Redmi A5"
                # instead of the raw ro.product.model code ("25028RN03A"),
                # and the monitor caches it per serial so probing stays
                # one-per-connect. Fall back to our own getprop (marketname
                # first, then model) only while the monitor is not running.
                m = re.search(r"\bname=([^\n\r]+)", monitor)
                device_name_str = m.group(1).strip() if m else ""
                if online and not device_name_str:
                    rc, out_n, _err2 = run_adb(
                        ["shell", "getprop", "ro.product.marketname"],
                        timeout=6)
                    if rc == 0 and out_n.strip():
                        device_name_str = out_n.strip()
                    else:
                        rc, out_n, _err2 = run_adb(
                            ["shell", "getprop", "ro.product.model"],
                            timeout=6)
                        device_name_str = out_n.strip() if rc == 0 else ""
                err = ""
            except Exception as exc:
                online, forwarded, service, monitor, err = (
                    False, False, "", "", f"poll error: {exc}")
                device_name_str = ""
            GLib.idle_add(self._apply_status, online and forwarded,
                          device_name_str, service, err, monitor)
        threading.Thread(target=worker, daemon=True).start()
        return True  # keep the timer running

    def _query_monitor(self):
        """Ask the background monitor over its control socket; '' = offline."""
        try:
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.settimeout(2)
            s.connect(os.path.join(DATA_DIR, "micsource.sock"))
            s.sendall(b"status")
            # 256-byte buffer: the status line can carry name=<model>, and
            # 64 truncated it off the end (same fix the CLI got).
            resp = s.recv(256).decode(errors="ignore").strip()
            s.close()
            return resp
        except Exception:
            return ""

    def _apply_status(self, connected, device_name_str, service, err, monitor):
        """Two user-facing rows only: Device and Monitoring. The systemd
        unit name ("background service") is an implementation detail; the
        seconds counter moved to the level bar + CLI status."""
        global last_notified

        if connected and device_name_str:
            self.row_device.set_subtitle(device_name_str)
        else:
            self.row_device.set_subtitle(
                "connected" if connected else "disconnected")
        if err:
            self.row_error.set_subtitle(err)
        self.row_error.set_visible(bool(err))

        if monitor:
            mon = ("on — phone audio is streaming" if connected
                   else "on — waiting for the phone")
        elif service == "active":
            mon = "starting…"
        else:
            mon = "off"
        self.row_monitor.set_subtitle(mon)

        self.btn_service_start.set_sensitive(service != "active")
        self.btn_service_stop.set_sensitive(service == "active")

        # Notification on connect/disconnect transitions (skip first check).
        if last_notified is not None and connected != last_notified:
            if connected:
                self._notify("MicSource device connected",
                             "Device linked and socket forwarding is active.")
            else:
                self._notify("MicSource device disconnected",
                             "Connect the phone and authorize adb debugging.")
        last_notified = connected
        return False  # one-shot idle callback

    # ------------------------------------------------------------------
    # Preferences (Adwaita preferences dialog; instant apply, no Save)
    # ------------------------------------------------------------------
    def _on_preferences_action(self, _action, _param):
        self._open_preferences()

    def _open_preferences(self):
        try:
            dlg = Adw.PreferencesDialog()
        except (AttributeError, TypeError):  # libadwaita < 1.5
            dlg = Adw.PreferencesWindow(transient_for=self.window)
        try:
            dlg.set_search_enabled(True)
        except Exception:
            pass
        self._pref = dlg

        # ---- page 1: Startup & Panel --------------------------------------
        # Title + icon go on the page itself: Adw.PreferencesDialog renders
        # one header switcher tab per page from these properties, and a
        # page without them gets blank/broken-image tabs (user-visible
        # glitch). Also shown in the Adw.PreferencesWindow sidebar.
        page = Adw.PreferencesPage(
            title="Startup & Panel",
            icon_name="applications-system-symbolic")
        dlg.add(page)

        grp = Adw.PreferencesGroup(
            title="Startup & Panel",
            description="How MicSource appears on your desktop")
        page.add(grp)

        # Auto-start service at login (systemd user unit).
        svc_ok = bool(shutil.which("systemctl")) and os.path.isfile(UNIT_FILE)
        svc_row, svc_watch, svc_get, svc_set = _make_switch_row(
            "Auto-start Service at Login",
            "Runs the background audio service when you log in")
        self._wire_toggle(svc_row, svc_watch, svc_get, svc_set,
                          self._get_autostart, self._apply_autostart,
                          sensitive=svc_ok,
                          unavailable="systemd unit missing (re-run install.sh)")
        grp.add(svc_row)

        # GNOME top-bar tile.
        gn_ok = bool(shutil.which("gnome-extensions"))
        tile_row, tile_watch, tile_get, tile_set = _make_switch_row(
            "GNOME Top-bar Tile",
            "MicSource status and controls in the GNOME panel")
        self._wire_toggle(tile_row, tile_watch, tile_get, tile_set,
                          self._get_tile, self._apply_tile,
                          sensitive=gn_ok,
                          unavailable="gnome-extensions not available "
                                      "on this system")
        grp.add(tile_row)

        # Opt-in AppIndicator tray (KDE/XFCE/etc.; GNOME users use the tile).
        tray_ok = os.path.isfile(TRAY_PATH)
        tray_row, tray_watch, tray_get, tray_set = _make_switch_row(
            "Tray Icon (AppIndicator)",
            "Legacy tray icon for KDE/XFCE/other desktops")
        self._wire_toggle(tray_row, tray_watch, tray_get, tray_set,
                          self._get_tray, self._apply_tray,
                          sensitive=tray_ok,
                          unavailable="tray not installed (re-run install.sh)")
        grp.add(tray_row)

        # ---- page 2: Audio -------------------------------------------------
        page2 = Adw.PreferencesPage(
            title="Audio", icon_name="audio-input-microphone-symbolic")
        dlg.add(page2)

        grp2 = Adw.PreferencesGroup(
            title="Audio Pipeline",
            description="Changes are written to the config and applied the "
                        "next time the service starts")
        page2.add(grp2)

        vmic_row, vmic_watch, vmic_get, vmic_set = _make_switch_row(
            "Virtual Microphone",
            "Expose the phone as a “phone-mic” input device for apps")
        self._wire_toggle(vmic_row, vmic_watch, vmic_get, vmic_set,
                          lambda: _cfg_bool("audio", "virtual_mic", True),
                          lambda on: (_cfg_set_bool("audio", "virtual_mic", on),
                                      "virtual-mic preference saved"),
                          sensitive=True, unavailable="")
        grp2.add(vmic_row)

        spk_row, spk_watch, spk_get, spk_set = _make_switch_row(
            "Play Phone Audio to Speakers",
            "Also send the phone sound to the desktop speakers")
        self._wire_toggle(spk_row, spk_watch, spk_get, spk_set,
                          lambda: _cfg_bool("audio", "play_to_speakers", False),
                          lambda on: (_cfg_set_bool("audio", "play_to_speakers", on),
                                      "play-to-speakers preference saved"),
                          sensitive=True, unavailable="")
        grp2.add(spk_row)

        dlg.present(self.window) if isinstance(dlg, Adw.PreferencesDialog) \
            else dlg.present()

    def _wire_toggle(self, row, watch, get_active, set_active,
                     getter, apply, *, sensitive, unavailable):
        """Connect a switch row to a live getter/apply pair (instant apply).

        Clicks are read through a one-tick-deferred fresh `get_active()`,
        not from the triggering signal: some libadwaita versions emit
        `activated` before the internal switch commits, so a synchronous
        read there returned the pre-click state and every tap applied
        the inverse of the click (user-visible: switching off said
        "Setting turned on." and enabled the tile instead).
        Programmatic writes (getter init, post-apply re-sync) block the
        notify handler for the duration — one-shot "consume next notify"
        flags latch forever when the value already matches the switch
        (no notify fires then), which silently ate the user's next real
        click (switch reacted to nothing at all).

        Both click sources (notify::active and row `activated`) funnel
        into `_begin_toggle()`; the in-flight lock makes the duplicate
        harmless — the scheduled deferred read applies the first commit
        only, and extra clicks while an apply is running are swallowed.
        """
        self._toggle_inflight = getattr(self, "_toggle_inflight", {})

        def on_notify(_watch, _pspec):
            self._begin_toggle(row, get_active, apply, getter, sync)

        def sync(value):
            # Programmatic write: block our own notify handler while the
            # property is set, then unblock. No latch, no stale flag.
            watch.handler_block_by_func(on_notify)
            try:
                set_active(bool(value))
            finally:
                watch.handler_unblock_by_func(on_notify)

        # Handlers must be connected *before* the first programmatic
        # sync: handler_block_by_func() raises for unconnected handlers,
        # which killed the whole preferences dialog (user report).
        watch.connect("notify::active", on_notify)
        # Second click source (row activation may emit before the switch
        # commits on some libadwaita versions; the deferred read below
        # makes its ordering irrelevant). The in-flight lock coalesces.
        row.connect("activated",
                    lambda _r: self._begin_toggle(row, get_active, apply,
                                                  getter, sync))

        sync(getter())
        row.set_sensitive(sensitive)
        if not sensitive and unavailable:
            row.set_subtitle(row.get_subtitle() + " — " + unavailable)

    def _begin_toggle(self, row, get_active, apply, getter, sync):
        if self._toggle_inflight.get(id(row)):
            return  # extra activation while an apply is running — swallow
        self._toggle_inflight[id(row)] = True
        GLib.idle_add(self._deferred_toggle, row, get_active, apply,
                      getter, sync)

    def _deferred_toggle(self, row, get_active, apply, getter, sync):
        # One main-loop tick after the click: the switch has committed
        # its flip, so get_active() is the post-click state regardless of
        # signal ordering on this libadwaita version.
        state = bool(get_active())
        self._run_toggle(apply, state, row, sync, getter)
        return False

    def _run_toggle(self, apply, state, row, sync, getter):
        """Apply a toggle off the main thread; re-sync + toast on truth.

        The getter runs *after* the apply so the switch is set to the
        verified state — a click that the shell merely accepted without
        honouring (rc=0, no effect) can never leave a lying switch.
        """

        def worker():
            try:
                ok, msg = apply(bool(state))
            except Exception as exc:  # noqa: BLE001
                ok, msg = False, str(exc)
            final = bool(state)
            try:
                final = bool(getter())
            except Exception:
                pass
            GLib.idle_add(self._toggle_done, ok, msg, final, row, sync)

        threading.Thread(target=worker, daemon=True).start()

    def _toggle_done(self, ok, msg, final, row, sync):
        self._toggle_inflight.pop(id(row), None)
        sync(final)  # truth wins, in both directions
        if not ok:
            self._toast(f"Could not apply: {msg or 'unknown error'}")
            self.log_line(f"setting FAILED: {msg or 'unknown error'} "
                          f"(state now: {'on' if final else 'off'})")
            return False
        self._toast("Setting turned on." if final else "Setting turned off.")
        self.log_line(f"setting applied: {msg or 'ok'} "
                      f"(state now: {'on' if final else 'off'})")
        return False

    # -- per-toggle getters/apply (run in worker threads) -----------------
    def _get_autostart(self):
        rc, out = _run_cmd(["systemctl", "--user", "is-enabled", SYSTEMD_UNIT])
        return rc == 0 and out.strip() == "enabled"

    def _apply_autostart(self, on):
        args = (["systemctl", "--user", "enable", "--quiet"]
                if on else ["systemctl", "--user", "disable", "--quiet"])
        rc, out = _run_cmd(args + [SYSTEMD_UNIT])
        if rc != 0:
            return False, out or "systemctl failed"
        return True, ("service enabled at login" if on
                      else "service autostart disabled")

    def _get_tile(self):
        rc, out = _run_cmd(["gnome-extensions", "info", EXT_ID])
        if rc != 0:
            return False
        for line in out.splitlines():
            stripped = line.strip()
            if stripped.startswith("State:"):
                state = stripped.split(":", 1)[1].strip().upper()
                # ACTIVE is the only real "on" (prefix-tolerant: some
                # shells annotate "ACTIVE (ERROR)"). Everything else —
                # DISABLED, UNINSTALLED, OUT OF DATE, ERROR, and crucially
                # INACTIVE, which is what GNOME 45+ prints after a
                # disable — is off. The old blacklist treated INACTIVE
                # as on, so the getter reported a *hidden* tile as on
                # and every verified re-sync snapped the switch back
                # (root cause of the "toggle does nothing" reports).
                return state.startswith("ACTIVE")
        return False

    def _apply_tile(self, on):
        args = (["gnome-extensions", "enable", EXT_ID] if on
                else ["gnome-extensions", "disable", EXT_ID])
        rc, out = _run_cmd(args)
        if rc != 0:
            return False, out or "gnome-extensions failed"
        # rc=0 only means gnome-shell accepted the state change; it applies
        # asynchronously. Confirm before claiming success (reports of the
        # switch leaving the tile in the wrong state).
        for _ in range(6):
            if self._get_tile() is on:
                return True, ("top-bar tile enabled" if on
                              else "top-bar tile disabled")
            time.sleep(0.3)
        # May have raced the shell; nudge once and confirm again.
        _run_cmd(args)
        for _ in range(6):
            if self._get_tile() is on:
                return True, ("top-bar tile enabled" if on
                              else "top-bar tile disabled")
            time.sleep(0.3)
        return False, ("gnome-shell did not confirm the tile is "
                       + ("on" if on else "off") + " within ~3 s")

    # -- tray helpers (probe in a separate process; Gtk 3 must never be
    # imported into this Gtk 4 process) -----------------------------------
    TRAY_PROBE = (
        "import gi\n"
        "gi.require_version('Gtk', '3.0')\n"
        "from gi.repository import Gtk  # noqa\n"
        "try:\n"
        "    gi.require_version('AppIndicator3', '0.1')\n"
        "    from gi.repository import AppIndicator3  # noqa\n"
        "except (ImportError, ValueError):\n"
        "    gi.require_version('AyatanaAppIndicator3', '0.1')\n"
        "    from gi.repository import AyatanaAppIndicator3  # noqa\n")

    def _tray_bindings_ok(self):
        """Gtk 3 + an AppIndicator client binding importable? Probed in a
        subprocess."""
        try:
            proc = subprocess.run(
                [sys.executable, "-c", self.TRAY_PROBE],
                capture_output=True, text=True, timeout=10)
            return proc.returncode == 0
        except Exception:
            return False

    def _tray_display_hint(self):
        """Warning for desktops needing extra bits to *render* the icon
        (GNOME has no native StatusNotifier area — the KStatusNotifier /
        AppIndicator shell extension is required)."""
        if "GNOME" not in os.environ.get("XDG_CURRENT_DESKTOP", ""):
            return ""
        candidates = (
            os.path.expanduser("~/.local/share/gnome-shell/extensions/"
                               "appindicatorsupport@rgcjonas.gmail.com"),
            "/usr/share/gnome-shell/extensions/"
            "appindicatorsupport@rgcjonas.gmail.com")
        for path in candidates:
            if os.path.isdir(path):
                return ""
        return ("on GNOME the icon also needs the KStatusNotifier/"
                "AppIndicator shell extension")

    def _get_tray(self):
        return os.path.isfile(TRAY_DESKTOP)

    def _apply_tray(self, on):
        if on:
            # Preflight: with the bindings missing, the tray script cannot
            # start at all — previously that failure was invisible (the
            # spawn rc still read as success, no icon appeared, and the
            # script's own legacy fallback even opened a second control
            # window). Fail here with the exact packages instead.
            if not self._tray_bindings_ok():
                return False, (
                    "AppIndicator bindings missing — install "
                    "gir1.2-gtk-3.0 and gir1.2-ayatanaappindicator3-0.1 "
                    "(or re-run install.sh; it prints the exact packages)")
            hint = self._tray_display_hint()
            os.makedirs(os.path.dirname(TRAY_DESKTOP), exist_ok=True)
            desktop = (
                "[Desktop Entry]\n"
                "Type=Application\n"
                "Name=MicSource Tray\n"
                "Comment=MicSource status icon (opens the control window "
                "when no tray is available)\n"
                f"Exec={CLI_PATH} tray\n"
                f"TryExec={CLI_PATH}\n"
                "Icon=micsource\n"
                "Terminal=false\n"
                "Categories=Utility;AudioVideo;\n")
            with open(TRAY_DESKTOP, "w") as fh:
                fh.write(desktop)
            try:
                if not os.path.isfile(TRAY_DESKTOP):
                    return False, "cannot write autostart entry"
                subprocess.Popen([CLI_PATH, "tray"],
                                 stdout=subprocess.DEVNULL,
                                 stderr=subprocess.DEVNULL,
                                 start_new_session=True)
            except Exception as exc:  # noqa: BLE001
                return False, f"cannot start tray: {exc}"
            return True, ("tray icon enabled (autostart entry written)"
                          + (f" — {hint}" if hint else ""))
        try:
            os.remove(TRAY_DESKTOP)
        except FileNotFoundError:
            pass
        _run_cmd(["pkill", "-f", TRAY_PATH], timeout=5)  # stop a live tray
        return True, "tray icon disabled (autostart entry removed)"

    # ------------------------------------------------------------------
    # About
    # ------------------------------------------------------------------
    def _on_about_action(self, _action, _param):
        try:
            dlg = Adw.AboutDialog()
        except (AttributeError, TypeError):  # libadwaita < 1.2
            self._error_dialog(
                "MicSource",
                "MicSource — use your Android phone as a microphone on "
                "Linux.\nadb forward + PulseAudio/PipeWire virtual mic.")
            return
        dlg.set_application_name("MicSource")
        dlg.set_developer_name("MicSource contributors")
        dlg.set_version("2")
        dlg.set_comments("Use your Android phone as a real microphone on "
                         "Linux (adb + PipeWire/PulseAudio virtual mic).")
        dlg.set_license_type(Gtk.License.MIT_X11)
        dlg.present(self.window)

    # ------------------------------------------------------------------
    # Actions
    # ------------------------------------------------------------------
    def on_service_start(self, _btn):
        self._service_action("start")

    def on_service_stop(self, _btn):
        self._service_action("stop")

    def _service_action(self, verb):
        self.log_line(f"service: {verb}…")
        if verb == "start":
            args = ["enable", "--now", "--quiet"]
        else:
            args = ["stop"]

        def worker():
            ok = False
            out = ""
            try:
                proc = subprocess.run(
                    ["systemctl", "--user", *args, SYSTEMD_UNIT],
                    capture_output=True, text=True, timeout=15)
                ok = proc.returncode == 0
                out = ((proc.stdout or "") + (proc.stderr or "")).strip()
            except FileNotFoundError:
                out = "systemctl not found on this system"
            except Exception as exc:
                out = str(exc)
            GLib.idle_add(self._service_done, verb, ok, out)

        threading.Thread(target=worker, daemon=True).start()

    def _service_done(self, verb, ok, out):
        if self.window and self.window.get_mapped():
            self._refresh()
        self.log_line(f"service {verb}: {'ok' if ok else 'FAILED'}"
                      f"{(' — ' + out) if out else ''}")
        if ok:
            self._notify(f"MicSource service {verb}ed",
                         "Monitoring now runs in the background.")
        else:
            self._notify("MicSource service error",
                         out or "systemctl failed", "dialog-error")
        return False

    def on_install_apk(self, _btn):
        if self.btn_install is not None and not self.btn_install.get_sensitive():
            return  # already running (row clicks share the same button)
        self.log_line("install-apk: running…")
        self.btn_install.set_sensitive(False)

        def worker():
            try:
                proc = subprocess.run(
                    ["bash", CLI_PATH, "install-apk"],
                    capture_output=True, text=True, timeout=240)
                out = ((proc.stdout or "") + (proc.stderr or "")).strip()
                code = proc.returncode
            except FileNotFoundError:
                code, out = 1, "micsource CLI not found; run install.sh first"
            except subprocess.TimeoutExpired as exc:
                code, out = 1, f"install-apk timed out: {exc}"
            GLib.idle_add(self._install_done, code, out)

        threading.Thread(target=worker, daemon=True).start()

    def _install_done(self, code, out):
        self.btn_install.set_sensitive(True)
        short = (out or "unknown error")[-1200:]
        if code == 0:
            self.log_line("install-apk: OK")
            self._notify("MicSource install complete",
                         "APK installed on the device; forwarding configured.")
        else:
            self.log_line(f"install-apk FAILED:\n{short}")
            self._notify("MicSource install failed", short[:200], "dialog-error")
            self._error_dialog("install-apk failed", short)
        if self.window and self.window.get_mapped():
            self._refresh()
        return False

    def on_open_config(self, _btn):
        try:
            subprocess.Popen(["xdg-open", CONFIG_DIR])
        except FileNotFoundError:
            self.log_line(f"config folder: {CONFIG_DIR}")

    def on_build_apk(self, _btn):
        if self.btn_build is not None and not self.btn_build.get_sensitive():
            return  # already running (row clicks share the same button)
        self.log_line("build-apk: running Gradle…"
                      " (first run can take several minutes)")
        self.btn_build.set_sensitive(False)

        def worker():
            try:
                proc = subprocess.run(
                    ["bash", BUILD_PATH], capture_output=True, text=True,
                    timeout=1800)
                out = ((proc.stdout or "") + (proc.stderr or "")).strip()
                code = proc.returncode
            except FileNotFoundError:
                code, out = 1, "micsource-build helper not found; run install.sh"
            except subprocess.TimeoutExpired:
                code, out = 1, "build-apk timed out"
            install_code = None
            install_out = ""
            if code == 0:
                # The build script already staged the APK; install it next.
                try:
                    iproc = subprocess.run(
                        ["bash", CLI_PATH, "install-apk"],
                        capture_output=True, text=True, timeout=240)
                    install_out = ((iproc.stdout or "") + (iproc.stderr or "")).strip()
                    install_code = iproc.returncode
                except subprocess.TimeoutExpired:
                    install_code, install_out = 1, "install-apk timed out"
                except FileNotFoundError:
                    install_code, install_out = 1, "micsource CLI not found"
            GLib.idle_add(self._build_done, code, out, install_code, install_out)

        threading.Thread(target=worker, daemon=True).start()

    def _build_done(self, code, out, install_code, install_out):
        self.btn_build.set_sensitive(True)
        short = (out or "unknown error")[-1500:]
        if code == 0:
            self.log_line("build-apk: OK (APK staged)")
            self._notify("MicSource build complete",
                         "APK built from source and staged.")
            if install_code is not None:
                if install_code == 0:
                    self.log_line("install-apk: OK (device install + forward)")
                    self._notify("MicSource install complete",
                                 "New APK installed on the device.")
                else:
                    self.log_line(f"install-apk FAILED:\n{install_out[-800:]}")
                    self._notify("MicSource device install failed",
                                 install_out[-200:] or "see the activity log",
                                 "dialog-error")
            if self.window and self.window.get_mapped():
                self._refresh()
            return False
        self.log_line(f"build-apk FAILED:\n{short}")
        self._notify("MicSource build failed", short[:200], "dialog-error")
        self._error_dialog("build-apk failed", short)
        return False


def _log_crash(trace):
    """Append a crash traceback to the gui log (visible from the app
    drawer, where stderr goes nowhere)."""
    log = os.path.join(DATA_DIR, "gui.log")
    try:
        with open(log, "a") as fh:
            fh.write("--- %s ---\n%s\n" % (
                time.strftime("%Y-%m-%d %H:%M:%S"), trace))
    except OSError:
        pass
    return log


def _install_excepthook():
    """Route any Python exception inside GLib callbacks to gui.log.

    PyGObject normally prints callback tracebacks straight to stderr,
    which the app drawer discards -- the window would just never show.
    """
    def _hook(tp, val, tb):
        import traceback
        _log_crash("".join(traceback.format_exception(tp, val, tb)))
        sys.__excepthook__(tp, val, tb)
    sys.excepthook = _hook


def main():
    _install_excepthook()
    _load_config()
    try:
        MicSourceApp().run([])
    except Exception:
        import traceback
        log = _log_crash(traceback.format_exc())
        print("MicSource window crashed (logged to %s):" % log,
              file=sys.stderr)
        sys.stderr.flush()


if __name__ == "__main__":
    main()
