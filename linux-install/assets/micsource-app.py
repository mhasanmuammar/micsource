#!/usr/bin/env python3
"""
MicSource desktop control window (GTK 4 + libadwaita).

Launched from the app drawer (via the micsource-gui wrapper), the CLI
(`micsource window`), or the GNOME top-bar tile's "Open Control Window".

The main window is intentionally one page:

  * Device + Monitoring status (the Monitoring row carries a real-time
    input level bar fed by the background service's metering)
  * One Start/Stop button for the background service (the only audio pump)
  * Connected-device selection
  * Wireless debugging, collapsed until needed
  * A link to the Android APK on the latest GitHub release

The APK is no longer built or installed from the host: GitHub Actions
publishes it as a release asset. The header menu opens Preferences
(auto-start, GNOME tile, tray, audio routing) and About.
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

from micsource_adb import (
    DEFAULT_SERVER_PORT,
    command as adb_command,
    server_port_error,
    validate_server_port,
)

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
from gi.repository import Adw, Gio, GLib, Gtk  # noqa: E402

APP_TITLE = "MicSource"
SYSTEMD_UNIT = "micsource.service"
try:
    import sys as _sys
    _sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    from paths import (DATA_DIR, CONFIG_DIR, CONFIG_PATH, ADB_PATH_FILE,
                      CLI_PATH, TRAY_PATH, TRAY_DESKTOP, UNIT_FILE,
                      CONTROL_SOCKET, STATE_DIR, RUNTIME_DIR,
                      APP_ID, IS_FLATPAK, EXT_ID, GNOME_EXT_SRC,
                      GNOME_EXT_DIR, MONITOR_PATH, GUI_PATH)
except Exception:
    DATA_DIR = os.path.expanduser("~/.local/share/micsource")
    CONFIG_DIR = os.path.expanduser("~/.config/micsource")
    CONFIG_PATH = os.path.join(CONFIG_DIR, "config.ini")
    ADB_PATH_FILE = os.path.join(DATA_DIR, "adb.path")
    CLI_PATH = os.path.join(DATA_DIR, "micsource")
    TRAY_PATH = os.path.join(DATA_DIR, "micsource-tray.py")
    TRAY_DESKTOP = os.path.expanduser("~/.config/autostart/micsource-tray.desktop")
    UNIT_FILE = os.path.expanduser("~/.config/systemd/user/micsource.service")
    CONTROL_SOCKET = os.path.join(DATA_DIR, "micsource.sock")
    STATE_DIR = os.path.expanduser("~/.local/state/micsource")
    RUNTIME_DIR = os.path.expanduser("/run/user/%d/micsource" % os.getuid())
    APP_ID = "io.github.mhasanmuammar.MicSource"
    IS_FLATPAK = False
    EXT_ID = "micsource-tile@micsource.local"
    GNOME_EXT_SRC = os.path.join(DATA_DIR, "gnome")
    GNOME_EXT_DIR = os.path.expanduser(
        "~/.local/share/gnome-shell/extensions/" + EXT_ID)
    MONITOR_PATH = os.path.join(DATA_DIR, "micsource-monitor.py")
    GUI_PATH = os.path.join(DATA_DIR, "micsource-gui")

DBUS_PATH = "/io/github/mhasanmuammar/MicSource"
CONTROL_IFACE = APP_ID + ".Control"
CONTROL_XML = """
<node>
  <interface name="%s">
    <method name="GetStatus">
      <arg type="a{sv}" direction="out"/>
    </method>
    <method name="Start"/>
    <method name="Stop"/>
    <method name="ShowWindow"/>
    <method name="InstallTile"/>
    <method name="RemoveTile"/>
    <method name="SetAutostart">
      <arg type="b" direction="in"/>
    </method>
    <signal name="StatusChanged">
      <arg type="a{sv}"/>
    </signal>
  </interface>
</node>
""" % CONTROL_IFACE


ANDROID_PKG = "fr.dzx.audiosource"  # Android package (baked into the APK)
DEVICE_SOCKET = "audiosource"       # device-side socket (RecordThread)
DEFAULT_HOST_SOCKET = "micsource"   # host side of the adb forward
RELEASES_URL = "https://github.com/mhasanmuammar/micsource/releases/latest"

last_notified = None

ADB_CMD = "adb"
ADB_SERVER_PORT = DEFAULT_SERVER_PORT
SERIAL = None
HOST_SOCKET = DEFAULT_HOST_SOCKET


def _log(msg):
    print(f"[micsource-app] {msg}", flush=True)


def _load_config():
    global ADB_CMD, ADB_SERVER_PORT, SERIAL, HOST_SOCKET
    global ANDROID_PKG, DEVICE_SOCKET
    adb_path = ""
    server_port = str(DEFAULT_SERVER_PORT)
    env_port = os.environ.get("MICSOURCE_ADB_SERVER_PORT", "").strip()
    if env_port:
        server_port = env_port
    serial = ""
    host_socket = ""
    android_pkg = ANDROID_PKG
    device_socket = DEVICE_SOCKET
    parser = configparser.ConfigParser()
    try:
        parser.read(CONFIG_PATH)
        adb_path = parser.get("adb", "adb_path", fallback="").strip()
        server_port = parser.get("adb", "server_port", fallback=server_port).strip()
        serial = parser.get("device", "serial", fallback="").strip()
        host_socket = parser.get("socket", "host_socket_name", fallback="").strip()
        android_pkg = parser.get("android", "package", fallback=android_pkg).strip()
        device_socket = parser.get("android", "device_socket", fallback=device_socket).strip()
    except Exception:
        pass
    if not adb_path:
        try:
            with open(ADB_PATH_FILE) as fh:
                adb_path = fh.read().strip()
        except OSError:
            adb_path = ""
    ADB_CMD = adb_path or "adb"
    try:
        ADB_SERVER_PORT = validate_server_port(server_port)
    except ValueError as exc:
        ADB_SERVER_PORT = DEFAULT_SERVER_PORT
        _log(f"invalid [adb] server_port ({exc}); using {DEFAULT_SERVER_PORT}")
    SERIAL = serial or None
    HOST_SOCKET = host_socket or DEFAULT_HOST_SOCKET
    ANDROID_PKG = android_pkg
    DEVICE_SOCKET = device_socket


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
    cmd = adb_command(ADB_CMD, ADB_SERVER_PORT, args, SERIAL)
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        if proc.returncode:
            port_error = server_port_error(ADB_SERVER_PORT, proc.stderr)
            if port_error:
                _log(port_error)
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
    """Control window (Adwaita): status, service, device, prefs."""

    def __init__(self, service_mode=False):
        # Unique application: the GNOME extension and the CLI reach the
        # primary instance through the app ID's D-Bus name and its actions.
        # A D-Bus-activated start runs with --gapplication-service, which
        # must stay windowless until an action asks for the window.
        super().__init__(
            application_id=APP_ID,
            flags=Gio.ApplicationFlags.HANDLES_COMMAND_LINE)
        self._service_mode = service_mode
        self.window = None
        self.row_device = None
        self.row_monitor = None
        self.row_error = None
        self.btn_service = None
        self._service_active = False
        self._service_busy = False
        self.entry_pair_address = None
        self.entry_pair_code = None
        self.entry_connect_address = None
        self.device_dropdown = None
        self.device_choices = []
        self._pref = None          # open preferences dialog/window (toasts)
        self.meter = None          # input level bar (Monitoring row suffix)
        self._meter_value = 0.0    # last level reported by the service
        self._meter_on = False     # meter polling thread flag
        self._monitor_proc = None  # supervised monitor child (Flatpak/no systemd)
        self._monitor_wanted = False
        self._monitor_started = 0.0
        self._monitor_failures = 0
        self._holds = 0
        self._tray_proc = None
        self._status_cache = {}
        self._tile_cache = (False, False)
        self._autostart_cache = False
        self._status_emitted = None
        self._polling = False
        self._dbus_registered = False

        for name, handler in (
                ("start", self._action_start),
                ("stop", self._action_stop),
                ("show", self._action_show),
                ("background", self._action_background)):
            act = Gio.SimpleAction.new(name, None)
            act.connect("activate", handler)
            self.add_action(act)

        act = Gio.SimpleAction.new("preferences", None)
        act.connect("activate", self._on_preferences_action)
        self.add_action(act)
        act = Gio.SimpleAction.new("about", None)
        act.connect("activate", self._on_about_action)
        self.add_action(act)

    # ------------------------------------------------------------------
    # Application lifecycle / D-Bus activation
    # ------------------------------------------------------------------
    def do_startup(self):
        Adw.Application.do_startup(self)
        # Status polling must not depend on the window: the extension and
        # the CLI query the cached snapshot while MicSource runs headless.
        GLib.timeout_add_seconds(3, self._refresh)
        GLib.timeout_add_seconds(2, self._supervise_monitor)
        if _cfg_bool("app", "tray", False) and os.path.isfile(TRAY_PATH):
            self._start_tray()
        self._refresh()

    def do_command_line(self, command_line):
        args = command_line.get_arguments()[1:]
        if "--background" in args:
            self.activate_action("background", None)
        elif "--start" in args:
            self.activate_action("start", None)
        elif "--stop" in args:
            self.activate_action("stop", None)
        elif self._service_mode or "--gapplication-service" in args:
            # D-Bus activation: wait for the action that caused it.
            pass
        else:
            self.activate()
        return 0

    def do_activate(self):
        if self.window is not None:
            self.window.present()
            return

        self.window = Adw.ApplicationWindow(application=self)
        # Adaptive sizing: the content scroll page below keeps the window
        # usable at any height (GNOME HIG); 420x540 is just the default.
        self.window.set_default_size(420, 540)

        # Header bar (standard Adwaita window layout) + primary menu.
        header = Adw.HeaderBar(
            title_widget=Adw.WindowTitle(title="MicSource",
                                         subtitle="phone mic over USB or Wi-Fi"))
        menu_btn = Gtk.MenuButton()
        menu_btn.set_icon_name("open-menu-symbolic")
        menu_btn.set_tooltip_text("Menu")
        menu_model = Gio.Menu()
        menu_model.append("Preferences…", "app.preferences")
        menu_model.append("About MicSource", "app.about")
        menu_btn.set_menu_model(menu_model)
        header.pack_end(menu_btn)

        page = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12)
        page.set_margin_top(12)
        page.set_margin_bottom(12)
        page.set_margin_start(12)
        page.set_margin_end(12)

        # ---- status group (Settings-style property rows) -----------------
        status_group = Adw.PreferencesGroup(title="Status")
        page.append(status_group)

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

        # ---- one primary action: start/stop the only audio pump -----------
        self.btn_service = Gtk.Button(label="Start Service")
        self.btn_service.add_css_class("suggested-action")
        self.btn_service.connect("clicked", self.on_service_toggle)
        page.append(self.btn_service)

        # ---- device selection (kept separate from wireless controls) ------
        device_group = Adw.PreferencesGroup(title="Device")
        self.device_dropdown = Gtk.DropDown.new_from_strings(
            ["Refresh to list connected devices"])
        device_row = Adw.ActionRow(
            title="Connected devices",
            subtitle="USB and already connected Wi-Fi devices")
        device_row.add_suffix(self.device_dropdown)
        device_group.add(device_row)
        self._action_row_button(
            device_group, "Refresh devices",
            "List authorized, offline, and unauthorized devices",
            "Refresh", self.on_refresh_devices)
        self._action_row_button(
            device_group, "Use selected device",
            "MicSource stores the selected ADB serial",
            "Select", self.on_select_device)
        page.append(device_group)

        # ---- wireless debugging (collapsed until needed) ------------------
        if hasattr(Adw, "ExpanderRow"):
            wireless_group = Adw.PreferencesGroup()
            self.wireless_expander = Adw.ExpanderRow(
                title="Wireless debugging",
                subtitle="Pair and connect over Wi-Fi (Android 11+)")
            wireless_group.add(self.wireless_expander)
            wireless_container = self.wireless_expander
        else:  # libadwaita < 1.4
            wireless_group = Adw.PreferencesGroup(
                title="Wireless debugging",
                description="Pair and connect over Wi-Fi (Android 11+)")
            wireless_container = wireless_group

        def _add_row(container, row):
            if hasattr(container, "add_row"):
                container.add_row(row)
            else:
                container.add(row)

        self.entry_pair_address = Gtk.Entry(placeholder_text="Phone pairing address, e.g. 192.168.1.20:41000")
        self.entry_pair_address.set_hexpand(True)
        pair_address_row = Adw.ActionRow(title="Pairing address")
        pair_address_row.add_suffix(self.entry_pair_address)
        _add_row(wireless_container, pair_address_row)

        self.entry_pair_code = Gtk.Entry(placeholder_text="Six-digit temporary code")
        self.entry_pair_code.set_visibility(False)
        self.entry_pair_code.set_input_purpose(Gtk.InputPurpose.DIGITS)
        self.entry_pair_code.set_max_length(6)
        code_row = Adw.ActionRow(title="Pairing code")
        code_row.add_suffix(self.entry_pair_code)
        _add_row(wireless_container, code_row)

        self._action_row_button(
            wireless_container, "Pair phone",
            "Use the pairing port and temporary code shown by Android",
            "Pair", self.on_wireless_pair)

        self.entry_connect_address = Gtk.Entry(placeholder_text="Separate wireless connection address, e.g. 192.168.1.20:38000")
        self.entry_connect_address.set_hexpand(True)
        connect_address_row = Adw.ActionRow(title="Connection address")
        connect_address_row.add_suffix(self.entry_connect_address)
        _add_row(wireless_container, connect_address_row)

        self._action_row_button(
            wireless_container, "Connect phone",
            "Connect and create MicSource's audio socket forward",
            "Connect", self.on_wireless_connect)
        self._action_row_button(
            wireless_container, "Find Wi-Fi devices",
            "Optional ADB mDNS discovery; manual address entry also works",
            "Discover", self.on_wireless_discover)
        self._action_row_button(
            wireless_container, "Disconnect Wi-Fi device",
            "Disconnect the entered address",
            "Disconnect", self.on_wireless_disconnect)
        page.append(wireless_group)

        # ---- Android app distribution (GitHub Releases) -------------------
        app_group = Adw.PreferencesGroup(title="Android App")
        self._action_row_button(
            app_group, "Install on your phone",
            "Download the APK from the latest GitHub release",
            "Download", self.on_download_apk)
        page.append(app_group)

        # Adaptive page: clamped width (HIG single-column layout like
        # gnome-settings) inside a vertical scroll, so the window works
        # at any height instead of overflowing a fixed size.
        clamp = Adw.Clamp(maximum_size=600, tightening_threshold=500)
        clamp.set_child(page)
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

    # ------------------------------------------------------------------
    # Service actions (D-Bus, CLI, extension, window button)
    # ------------------------------------------------------------------
    def _action_start(self, _action, _param):
        self._start_monitor()
        self._hold()

    def _action_stop(self, _action, _param):
        self._stop_monitor()
        self._release()

    def _action_show(self, _action, _param):
        self.activate()

    def _action_background(self, _action, _param):
        self._start_monitor()
        self._hold()

    def _hold(self):
        self._holds += 1
        self.hold()

    def _release(self):
        if self._holds > 0:
            self._holds -= 1
            self.release()

    def _monitor_running(self):
        return (self._monitor_proc is not None
                and self._monitor_proc.poll() is None)

    def _start_monitor(self):
        """Start the audio pump as a supervised child (Flatpak / no systemd).

        The host install still prefers the systemd unit; this path is what
        makes the sandbox self-contained and gives the D-Bus actions a
        concrete process to drive.
        """
        if self._monitor_running():
            self._monitor_wanted = True
            return True, "already running"
        if not os.path.isfile(MONITOR_PATH):
            return False, "monitor not found (re-run install.sh)"
        env = os.environ.copy()
        env.setdefault("MICSOURCE_DATA_DIR", DATA_DIR)
        env.setdefault("MICSOURCE_CONFIG_DIR", CONFIG_DIR)
        env.setdefault("MICSOURCE_STATE_DIR", STATE_DIR)
        env.setdefault("MICSOURCE_RUNTIME_DIR", RUNTIME_DIR)
        env.setdefault("MICSOURCE_ADB_SERVER_PORT", str(ADB_SERVER_PORT))
        try:
            log_path = os.path.join(STATE_DIR, "monitor.log")
            os.makedirs(STATE_DIR, exist_ok=True)
            log = open(log_path, "a", buffering=1)
        except OSError:
            log = subprocess.DEVNULL
        try:
            self._monitor_proc = subprocess.Popen(
                [sys.executable, MONITOR_PATH],
                stdin=subprocess.DEVNULL, stdout=log, stderr=log,
                env=env, start_new_session=True)
        except OSError as exc:
            return False, f"cannot start monitor: {exc}"
        self._monitor_wanted = True
        self._monitor_started = time.time()
        self.log_line("monitor started")
        return True, "monitor started"

    def _stop_monitor(self):
        self._monitor_wanted = False
        proc = self._monitor_proc
        self._monitor_proc = None
        if proc is not None and proc.poll() is None:
            try:
                proc.terminate()
                try:
                    proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    proc.kill()
            except OSError:
                pass
            self.log_line("monitor stopped")
        if self._tray_proc is not None:
            self._stop_tray()

    def _supervise_monitor(self):
        """Restart the monitor if it dies while it is wanted."""
        if not self._monitor_wanted:
            return True
        if self._monitor_running():
            self._monitor_failures = 0
            return True
        # Back off after repeated immediate crashes instead of spinning.
        if time.time() - self._monitor_started < 3:
            return True
        if self._monitor_failures >= 5:
            return True  # stop restarting; the log explains the failure
        self._monitor_failures += 1
        ok, msg = self._start_monitor()
        self.log_line(f"monitor restart: {msg}")
        return True

    def _start_tray(self):
        if (self._tray_proc is not None
                and self._tray_proc.poll() is None):
            return
        try:
            self._tray_proc = subprocess.Popen(
                [sys.executable, TRAY_PATH],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                start_new_session=True)
        except OSError as exc:
            self.log_line(f"tray failed to start: {exc}")

    def _stop_tray(self):
        proc = self._tray_proc
        self._tray_proc = None
        if proc is not None and proc.poll() is None:
            try:
                proc.terminate()
            except OSError:
                pass

    def do_shutdown(self):
        # Never leave an orphan audio pump behind on a clean Quit.
        if self._monitor_proc is not None:
            self._monitor_wanted = False
            try:
                self._monitor_proc.terminate()
            except OSError:
                pass
        self._stop_tray()
        Adw.Application.do_shutdown(self)

    # ------------------------------------------------------------------
    # D-Bus control interface (thin adapter over the same actions)
    # ------------------------------------------------------------------
    def do_dbus_register(self, connection, object_path):
        if not Adw.Application.do_dbus_register(self, connection, object_path):
            return False
        try:
            node = Gio.DBusNodeInfo.new_for_xml(CONTROL_XML)
            connection.register_object(
                object_path, node.interfaces[0], self._on_control_call,
                None, None)
            self._dbus_registered = True
            self._dbus_connection = connection
            self._dbus_object_path = object_path
        except Exception as exc:  # noqa: BLE001
            self.log_line(f"control interface unavailable: {exc}")
        return True

    def do_dbus_unregister(self, connection, object_path):
        if self._dbus_registered:
            try:
                connection.unregister_object(object_path)
            except Exception:
                pass
            self._dbus_registered = False
        Adw.Application.do_dbus_unregister(self, connection, object_path)

    def _on_control_call(self, _conn, _sender, _path, _iface, method,
                         params, invocation):
        try:
            if method == "GetStatus":
                invocation.return_value(
                    GLib.Variant("(a{sv})", (self._status_variant(),)))
            elif method in ("Start", "Stop", "ShowWindow", "InstallTile",
                            "RemoveTile", "SetAutostart"):
                if method == "Start":
                    self.activate_action("start", None)
                elif method == "Stop":
                    self.activate_action("stop", None)
                elif method == "ShowWindow":
                    GLib.idle_add(self.activate)
                elif method in ("InstallTile", "RemoveTile"):
                    want = method == "InstallTile"
                    threading.Thread(target=self._apply_tile,
                                     args=(want,), daemon=True).start()
                elif method == "SetAutostart":
                    on = bool(params.unpack()[0])
                    threading.Thread(target=self._apply_autostart,
                                     args=(on,), daemon=True).start()
                invocation.return_value(None)
            else:
                invocation.return_dbus_error(
                    "org.freedesktop.DBus.Error.UnknownMethod",
                    f"unknown method {method}")
        except Exception as exc:  # noqa: BLE001
            invocation.return_dbus_error(
                "org.freedesktop.DBus.Error.Failed", str(exc))

    def _status_variant(self):
        """Current snapshot as an a{sv} dictionary for D-Bus consumers."""
        monitor = self._status_cache.get("monitor", "")
        cache = self._status_cache
        connected = "device=1" in monitor and "forward=1" in monitor
        name = ""
        m = re.search(r"\bname=([^\n\r]+)", monitor)
        if m:
            name = m.group(1).strip()
        audio_seconds = dropped_seconds = 0
        m = re.search(r"audio_seconds=(\d+)", monitor)
        if m:
            audio_seconds = int(m.group(1))
        m = re.search(r"dropped_seconds=(\d+)", monitor)
        if m:
            dropped_seconds = int(m.group(1))
        installed, enabled = self._tile_cache
        values = {
            "device": GLib.Variant("b", connected),
            "monitoring": GLib.Variant("b", bool(monitor)),
            "name": GLib.Variant("s", name),
            "service": GLib.Variant(
                "s", "active" if cache.get("service") == "active"
                else "inactive"),
            "audio_seconds": GLib.Variant("t", audio_seconds),
            "dropped_seconds": GLib.Variant("t", dropped_seconds),
            "tile_installed": GLib.Variant("b", installed),
            "tile_enabled": GLib.Variant("b", enabled),
            "autostart": GLib.Variant("b", self._autostart_state()),
            "flatpak": GLib.Variant("b", IS_FLATPAK),
        }
        return values

    def _emit_status(self):
        if not self._dbus_registered:
            return
        payload = self._status_variant()
        if payload == self._status_emitted:
            return
        self._status_emitted = payload
        try:
            self._dbus_connection.emit_signal(
                None, self._dbus_object_path, CONTROL_IFACE,
                "StatusChanged", GLib.Variant("(a{sv})", (payload,)))
        except Exception:
            pass

    def _action_row_button(self, group, title, subtitle, label, handler):
        """HIG boxed-list row: title/subtitle with a flat button suffix.

        The row background activates the same handler (single control per
        row; the button remains visible for pointer users). Works for both
        Adw.PreferencesGroup and Adw.ExpanderRow containers.
        """
        btn = Gtk.Button(label=label, valign=Gtk.Align.CENTER)
        btn.add_css_class("flat")
        btn.connect("clicked", handler)
        row = Adw.ActionRow(title=title, subtitle=subtitle)
        row.add_suffix(btn)
        row.set_activatable_widget(btn)
        if hasattr(group, "add_row"):
            group.add_row(row)
        else:
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
                s.connect(CONTROL_SOCKET)
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
        # No in-window log: progress goes to the launcher's log (gui.log),
        # outcomes use toasts, notifications, or an error dialog.
        _log(line)

    def _toast(self, msg):
        """Show a toast in the preferences dialog (or log as fallback)."""
        if self._pref is not None:
            try:
                self._pref.add_toast(Adw.Toast.new(msg))
                return
            except Exception:
                pass
        self.log_line(msg)

    def _systemd_available(self):
        return (not IS_FLATPAK and bool(shutil.which("systemctl"))
                and os.path.isfile(UNIT_FILE))

    def _service_state(self):
        if not self._systemd_available():
            return "active" if self._monitor_running() else "inactive"
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
        if self._polling:
            return True  # previous probe still running; never stack threads
        self._polling = True

        def worker():
            try:
                online = device_online()
                forwarded = socket_forwarded() if online else False
                service = self._service_state()
                monitor = self._query_monitor()
                self._tile_cache = self._tile_state()
                self._autostart_cache = self._get_autostart()
                # Device model name: prefer the monitor's already-resolved
                # name — its probe chain (ro.product.marketname -> model ->
                # ...) yields user-facing marketing names such as "Redmi A5"
                # instead of the raw ro.product.model code ("25028RN03A"),
                # and the monitor caches it per serial so probing stays
                # one-per-connect. Fall back to our own getprop (marketname
                # first, then model) only while the monitor is not running.
                m = re.search(r"\bname=([^\n\r]+)", monitor)
                device_name_str = m.group(1).strip() if m else ""
                if online and not device_name_str and not monitor:
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
            s.connect(CONTROL_SOCKET)
            s.sendall(b"status")
            # 256-byte buffer: the status line can carry name=<model>, and
            # 64 truncated it off the end (same fix the CLI got).
            resp = s.recv(256).decode(errors="ignore").strip()
            s.close()
            return resp
        except Exception:
            return ""

    def _apply_status(self, connected, device_name_str, service, err, monitor):
        """Cache the snapshot for D-Bus, then paint the two status rows."""
        global last_notified

        self._polling = False
        self._status_cache = {
            "connected": connected,
            "name": device_name_str,
            "service": service,
            "monitor": monitor,
            "error": err,
        }
        if self.window is not None and self.row_device is not None:
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

            self._service_active = service == "active"
            if not self._service_busy:
                self.btn_service.set_label(
                    "Stop Service" if self._service_active
                    else "Start Service")
                self.btn_service.set_sensitive(True)
                for css in ("suggested-action", "destructive-action"):
                    self.btn_service.remove_css_class(css)
                self.btn_service.add_css_class(
                    "destructive-action" if self._service_active
                    else "suggested-action")
        self._emit_status()

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

        # Auto-start at login: systemd unit on the host, Background portal
        # inside the Flatpak (which must not write an XDG autostart file).
        if IS_FLATPAK:
            svc_ok = True
            svc_subtitle = ("Starts MicSource in the background when you "
                            "log in (desktop portal)")
            svc_unavailable = ""
        else:
            svc_ok = (bool(shutil.which("systemctl"))
                      and os.path.isfile(UNIT_FILE))
            svc_subtitle = ("Runs the background audio service when you "
                            "log in")
            svc_unavailable = "systemd unit missing (re-run install.sh)"
        svc_row, svc_watch, svc_get, svc_set = _make_switch_row(
            "Auto-start Service at Login", svc_subtitle)
        self._wire_toggle(svc_row, svc_watch, svc_get, svc_set,
                          self._get_autostart, self._apply_autostart,
                          sensitive=svc_ok,
                          unavailable=svc_unavailable)
        grp.add(svc_row)

        # GNOME top-bar tile. In the Flatpak the app installs the bundled
        # extension itself; on the host gnome-extensions does the enabling.
        gn_ok = IS_FLATPAK or bool(shutil.which("gnome-extensions"))
        tile_row, tile_watch, tile_get, tile_set = _make_switch_row(
            "GNOME Top-bar Tile",
            "MicSource status and controls in the GNOME panel")
        self._wire_toggle(tile_row, tile_watch, tile_get, tile_set,
                          self._get_tile, self._apply_tile,
                          sensitive=gn_ok,
                          unavailable="gnome-extensions not available "
                                      "on this system")
        grp.add(tile_row)

        # Opt-in StatusNotifier tray (KDE/XFCE/etc.; GNOME users may use tile).
        tray_ok = os.path.isfile(TRAY_PATH)
        tray_row, tray_watch, tray_get, tray_set = _make_switch_row(
            "Tray Icon (StatusNotifier)",
            "Status icon for StatusNotifier-capable desktops")
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
    def _bus_call(self, dest, path, interface, method, params,
                  timeout=8000):
        bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
        return bus.call_sync(dest, path, interface, method, params, None,
                             Gio.DBusCallFlags.NONE, timeout, None)

    def _shell_extension_state(self):
        """(installed_on_shell, enabled) from org.gnome.Shell.Extensions."""
        try:
            reply = self._bus_call(
                "org.gnome.Shell.Extensions",
                "/org/gnome/Shell/Extensions",
                "org.gnome.Shell.Extensions", "ListExtensions", None)
            (extensions,) = reply.deep_unpack()
            info = extensions.get(EXT_ID)
            if not info:
                return False, False
            # 1 = ENABLED, 2 = DISABLED, 3 = ERROR, 4 = OUT_OF_DATE.
            return True, info.get("state") == 1
        except Exception:
            return False, False

    def _tile_state(self):
        """(files installed, enabled) without assuming a host CLI exists."""
        installed = os.path.isfile(
            os.path.join(GNOME_EXT_DIR, "extension.js"))
        if IS_FLATPAK:
            on_shell, enabled = self._shell_extension_state()
            return installed or on_shell, enabled
        rc, out = _run_cmd(["gnome-extensions", "info", EXT_ID])
        if rc != 0:
            return installed, False
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
                return installed, state.startswith("ACTIVE")
        return installed, False

    def _get_autostart(self):
        if IS_FLATPAK:
            return _cfg_bool("app", "autostart", False)
        rc, out = _run_cmd(["systemctl", "--user", "is-enabled", SYSTEMD_UNIT])
        return rc == 0 and out.strip() == "enabled"

    def _autostart_state(self):
        return self._autostart_cache

    def _portal_request_background(self, on):
        """Ask the Background portal to autostart `micsource-gui --background`."""
        token = "micsource_%d" % int(time.time() * 1000)
        options = {
            "handle_token": GLib.Variant("s", token),
            "reason": GLib.Variant(
                "s", "Run the MicSource phone-microphone service at login"),
            "autostart": GLib.Variant("b", bool(on)),
            "commandline": GLib.Variant(
                "as", ["micsource-gui", "--background"]),
            "dbus-activatable": GLib.Variant("b", True),
        }
        self._bus_call(
            "org.freedesktop.portal.Desktop",
            "/org/freedesktop/portal/desktop",
            "org.freedesktop.portal.Background", "RequestBackground",
            GLib.Variant("(sa{sv})", ("", options)), timeout=15000)

    def _apply_autostart(self, on):
        if IS_FLATPAK:
            try:
                self._portal_request_background(on)
            except Exception as exc:  # noqa: BLE001
                return False, f"desktop portal unavailable: {exc}"
            _cfg_set_bool("app", "autostart", on)
            if on:
                _cfg_set_bool("app", "tray", _cfg_bool("app", "tray", False))
            return True, ("MicSource will start in the background at login"
                          if on else "login autostart disabled")
        args = (["systemctl", "--user", "enable", "--quiet"]
                if on else ["systemctl", "--user", "disable", "--quiet"])
        rc, out = _run_cmd(args + [SYSTEMD_UNIT])
        if rc != 0:
            return False, out or "systemctl failed"
        return True, ("service enabled at login" if on
                      else "service autostart disabled")

    def _get_tile(self):
        return self._tile_state()[1]

    def _apply_tile(self, on):
        if IS_FLATPAK:
            return self._apply_tile_flatpak(on)
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

    def _apply_tile_flatpak(self, on):
        """Install the bundled extension into the host Shell directory."""
        try:
            if on:
                os.makedirs(GNOME_EXT_DIR, exist_ok=True)
                for name in ("extension.js", "prefs.js", "metadata.json"):
                    src = os.path.join(GNOME_EXT_SRC, name)
                    dst = os.path.join(GNOME_EXT_DIR, name)
                    shutil.copy2(src, dst)
        except OSError as exc:
            return False, f"cannot install extension: {exc}"
        try:
            if on:
                # Reload makes the running Shell pick up newly copied files;
                # it fails harmlessly for an extension it has not seen yet.
                for method in ("ReloadExtension", "EnableExtension"):
                    try:
                        self._bus_call(
                            "org.gnome.Shell.Extensions",
                            "/org/gnome/Shell/Extensions",
                            "org.gnome.Shell.Extensions", method,
                            GLib.Variant("(s)", (EXT_ID,)))
                    except Exception:
                        pass
            else:
                self._bus_call(
                    "org.gnome.Shell.Extensions",
                    "/org/gnome/Shell/Extensions",
                    "org.gnome.Shell.Extensions", "DisableExtension",
                    GLib.Variant("(s)", (EXT_ID,)))
        except Exception as exc:  # noqa: BLE001
            return False, f"gnome-shell did not accept the change: {exc}"
        for _ in range(6):
            if self._get_tile() is on:
                return True, ("top-bar tile enabled" if on
                              else "top-bar tile disabled")
            time.sleep(0.5)
        if on:
            return False, ("extension files installed, but GNOME Shell has "
                           "not loaded it yet — log out and back in, then "
                           "enable the tile")
        return False, "gnome-shell did not confirm the tile is off"

    # -- tray helpers (probe the session-bus watcher in a subprocess) -----
    TRAY_PROBE = (
        "from gi.repository import Gio, GLib\n"
        "bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)\n"
        "answer = bus.call_sync(\n"
        "    'org.freedesktop.DBus', '/org/freedesktop/DBus',\n"
        "    'org.freedesktop.DBus', 'NameHasOwner',\n"
        "    GLib.Variant('(s)', ('org.kde.StatusNotifierWatcher',)),\n"
        "    None, Gio.DBusCallFlags.NONE, 3000, None)\n"
        "raise SystemExit(0 if answer.unpack()[0] else 3)\n")

    def _tray_watcher_ok(self):
        """Is a StatusNotifier host available on the session bus?"""
        try:
            proc = subprocess.run(
                [sys.executable, "-c", self.TRAY_PROBE],
                capture_output=True, text=True, timeout=10)
            return proc.returncode == 0
        except Exception:
            return False

    def _get_tray(self):
        if IS_FLATPAK:
            return _cfg_bool("app", "tray", False)
        return os.path.isfile(TRAY_DESKTOP)

    def _apply_tray(self, on):
        if on:
            if not self._tray_watcher_ok():
                return False, (
                    "no tray support on this desktop — no StatusNotifier "
                    "watcher on the session bus (GNOME needs the "
                    "appindicatorsupport shell extension)")
            if IS_FLATPAK:
                _cfg_set_bool("app", "tray", True)
                self._start_tray()
                return True, "tray icon enabled"
            os.makedirs(os.path.dirname(TRAY_DESKTOP), exist_ok=True)
            desktop = (
                "[Desktop Entry]\n"
                "Type=Application\n"
                "Name=MicSource Tray\n"
                "Comment=MicSource status and controls\n"
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
            return True, "tray icon enabled (autostart entry written)"
        if IS_FLATPAK:
            _cfg_set_bool("app", "tray", False)
            self._stop_tray()
            return True, "tray icon disabled"
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
    def on_service_toggle(self, _btn):
        if self._service_busy:
            return
        self._service_action("stop" if self._service_active else "start")

    def _service_action(self, verb):
        self._service_busy = True
        self.btn_service.set_sensitive(False)
        self.btn_service.set_label(
            "Stopping…" if verb == "stop" else "Starting…")
        self.log_line(f"service: {verb}…")

        def worker():
            ok = False
            out = ""
            try:
                if not self._systemd_available():
                    # Flatpak sandbox: no systemd; supervise the monitor
                    # as a supervised child process instead.
                    if verb == "start":
                        ok, out = self._start_monitor()
                    else:
                        self._stop_monitor()
                        ok = True
                        out = "monitor stopped"
                else:
                    args = ["enable", "--now", "--quiet"] \
                        if verb == "start" else ["stop"]
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
        self._service_busy = False
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
            self._error_dialog("Could not change the service",
                               out or "systemctl failed")
        return False

    def on_download_apk(self, _btn):
        """Open the latest GitHub release in the user's browser."""
        try:
            Gio.AppInfo.launch_default_for_uri(RELEASES_URL, None)
        except Exception:
            try:
                subprocess.Popen(["xdg-open", RELEASES_URL])
            except Exception as exc:
                self._error_dialog(
                    "Could not open the browser",
                    f"Download the APK from:\n{RELEASES_URL}\n\n({exc})")

    def _run_cli_async(self, args, callback, *, input_text=None, timeout=20):
        def worker():
            try:
                proc = subprocess.run(
                    ["bash", CLI_PATH, *args], input=input_text,
                    capture_output=True, text=True, timeout=timeout)
                output = ((proc.stdout or "") + (proc.stderr or "")).strip()
                code = proc.returncode
            except FileNotFoundError:
                code, output = 127, "MicSource CLI not found; run install.sh first"
            except subprocess.TimeoutExpired:
                code, output = 124, "ADB operation timed out"
            GLib.idle_add(callback, code, output)
        threading.Thread(target=worker, daemon=True).start()

    def on_refresh_devices(self, _btn):
        self.log_line("devices: listing connected phones…")
        self._run_cli_async(["devices"], self._devices_loaded, timeout=12)

    def _devices_loaded(self, code, output):
        choices = []
        for line in output.splitlines():
            fields = line.split()
            if len(fields) >= 2 and fields[1] in ("device", "offline", "unauthorized"):
                choices.append((fields[0], fields[1]))
        self.device_choices = choices
        labels = [f"{serial} — {state}" for serial, state in choices]
        if not labels:
            labels = ["No devices found; connect USB or enable Wireless debugging"]
        self.device_dropdown.set_model(Gtk.StringList.new(labels))
        self.device_dropdown.set_selected(0)
        for index, (serial, _state) in enumerate(choices):
            if serial == SERIAL:
                self.device_dropdown.set_selected(index)
                break
        self.log_line(output or "No ADB devices found.")
        if code:
            self._error_dialog("Could not list devices", output or "ADB failed")
        return False

    def on_select_device(self, _btn):
        index = self.device_dropdown.get_selected()
        if index >= len(self.device_choices):
            self._error_dialog("No device selected", "Refresh devices, then select an online authorized device.")
            return
        serial, state = self.device_choices[index]
        if state != "device":
            self._error_dialog("Device unavailable", f"{serial} is {state}. Authorize debugging on the phone and refresh.")
            return
        self._run_cli_async(["device-select", serial], self._device_selected)

    def _device_selected(self, code, output):
        self.log_line(output or "Device selection saved.")
        if code:
            self._error_dialog("Could not select device", output)
        else:
            _load_config()
            self._refresh()
            # Ensure the ADB forward is established so the device
            # appears connected in the status row.  This mirrors the
            # monitor's ensure_forward() and is needed because
            # on_select_device only sets the serial but does not
            # set up the host-side socket forward.
            try:
                run_adb(["forward", "--remove",
                         f"localabstract:{HOST_SOCKET}"], timeout=4)
                rc, _out, _err = run_adb(
                    ["forward", f"localabstract:{HOST_SOCKET}",
                     f"localabstract:{DEVICE_SOCKET}"],
                    timeout=6,
                )
                if rc != 0:
                    _log(f"failed to set up ADB forward (rc={rc}): "
                         f"{_err or _out or ''}")
            except Exception as exc:
                _log(f"error setting up ADB forward: {exc}")
            self._notify("MicSource device selected",
                         f"Now using {self.device_choices[self.device_dropdown.get_selected()][0]}.")
        return False

    def on_wireless_pair(self, _btn):
        endpoint = self.entry_pair_address.get_text().strip()
        code = self.entry_pair_code.get_text().strip()
        self.entry_pair_code.set_text("")
        if not re.fullmatch(r"[0-9]{6}", code):
            self._error_dialog("Invalid pairing code", "Enter the six-digit temporary code shown by Android.")
            code = ""
            return
        self.log_line(f"wireless-pair: pairing with {endpoint}…")
        self._run_cli_async(["wireless-pair", endpoint], self._wireless_pair_done,
                            input_text=code + "\n", timeout=45)
        code = ""

    def _wireless_pair_done(self, code, output):
        self.log_line(output or ("Wireless pairing complete." if code == 0 else "Wireless pairing failed."))
        if code:
            self._error_dialog("Wireless pairing failed", output or "Check that the temporary pairing address and code are current.")
        else:
            self._notify("Phone paired",
                         "Now connect with the separate wireless debugging address.")
        return False

    def on_wireless_connect(self, _btn):
        endpoint = self.entry_connect_address.get_text().strip()
        self.log_line(f"wireless-connect: connecting to {endpoint}…")
        self._run_cli_async(["wireless-connect", endpoint], self._wireless_connect_done,
                            timeout=30)

    def _wireless_connect_done(self, code, output):
        self.log_line(output or ("Wireless connection and audio forward active." if code == 0 else "Wireless connection failed."))
        if code:
            self._error_dialog("Wireless connection failed", output or "Check the connection address, network, and phone authorization.")
        else:
            _load_config()
            self._refresh()
            self._notify("Phone connected over Wi-Fi",
                         "Audio socket forwarding is active.")
        return False

    def on_wireless_discover(self, _btn):
        self._run_cli_async(["wireless-discover"], self._wireless_discovered,
                            timeout=15)

    def _wireless_discovered(self, code, output):
        self.log_line(output or "No Wireless debugging services discovered.")
        matches = []
        for line in output.splitlines():
            if "_adb-tls-connect._tcp" in line:
                match = re.search(r"(?:\s|^)(\[[^]]+\]:\d+|[A-Za-z0-9._-]+:\d+)\s*$", line)
                if match:
                    matches.append(match.group(1))
        if len(matches) == 1:
            self.entry_connect_address.set_text(matches[0])
            self._notify("Found a Wi-Fi device",
                         "Connection address filled in; review it and choose Connect.")
        elif len(matches) > 1:
            self._error_dialog("Multiple Wi-Fi devices found",
                               "Use the address of the phone you want in Connection address:\n\n" + "\n".join(matches))
        elif code:
            self._error_dialog("Discovery unavailable", output or "This ADB build may not support mDNS discovery; enter the phone's connection address manually.")
        return False

    def on_wireless_disconnect(self, _btn):
        endpoint = self.entry_connect_address.get_text().strip()
        args = ["wireless-disconnect"] + ([endpoint] if endpoint else [])
        self._run_cli_async(args, self._wireless_disconnect_done)

    def _wireless_disconnect_done(self, code, output):
        self.log_line(output or "Wireless device disconnected.")
        if code:
            self._error_dialog("Could not disconnect device", output)
        else:
            _load_config()
            self._refresh()
            self._notify("Wi-Fi device disconnected",
                         "MicSource is no longer connected to that address.")
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
