#!/usr/bin/env python3
"""
MicSource system tray icon — pure GLib/Gio StatusNotifierItem client.

Implements the AppIndicator/StatusNotifierItem protocol directly over the
session bus (org.kde.StatusNotifierItem + com.canonical.dbusmenu), with NO
Gtk-3 library and NO AppIndicator/Ayatana GIR bindings — anywhere PyGObject
(GLib/Gio) exists, this tray runs, with zero host packages.

What it does:
  * registers with org.kde.StatusNotifierWatcher (and re-registers when the
    watcher restarts),
  * exports /StatusNotifierItem (icon + tooltip) and a
    com.canonical.dbusmenu server at /StatusNotifierItem/menus/micsource,
  * shows connection state to the Android device via adb,
  * offers Start / Stop Service (the background service is the only
    audio pump; the tray itself never streams),
  * opens the control window and the config folder,
  * quits cleanly.

Audio flow (adb): device RecordService listens on abstract socket
"audiosource"; host runs `adb forward localabstract:micsource
localabstract:audiosource`, and this script pipes the PCM data to a
player through the monitor service.
"""
import configparser
import os
import socket
import subprocess
import sys
import threading
import time

try:
    from gi.repository import GLib, Gio
except Exception as _exc:  # PyGObject missing — log + exit 1 so the
    # prefs toggle reports it; never silently become another program.
    try:
        with open(os.path.join(
                os.path.expanduser("~/.local/share/micsource"),
                "tray.log"), "a") as _fh:
            _fh.write(f"tray unavailable (GLib/Gio missing): {_exc}\n")
    except OSError:
        pass
    print(f"[micsource-tray] PyGObject (GLib/Gio) not available: {_exc}",
          flush=True)
    raise SystemExit(1)

# Pure model functions below (menu_config, dbusmenu_props, build_layout,
# group_properties, status_name, tray_icon_name, sni_props) are unit-tested
# without PyGObject: linux-install/tests/test_tray_model.py imports this
# file with a fake-`gi` stub and exercises them.

APP_ID = "micsource"
APP_TITLE = "MicSource"
DATA_DIR = os.path.expanduser("~/.local/share/micsource")
CONFIG_DIR = os.path.expanduser("~/.config/micsource")
CONFIG_PATH = os.path.join(CONFIG_DIR, "config.ini")
ADB_PATH_FILE = os.path.join(DATA_DIR, "adb.path")
CLI_PATH = os.path.join(DATA_DIR, "micsource")
LOG_PATH = os.path.join(DATA_DIR, "tray.log")

ANDROID_PKG = "fr.dzx.audiosource"  # Android package (baked into the APK)
DEVICE_SOCKET = "audiosource"       # Device-side socket (RecordThread)
DEFAULT_HOST_SOCKET = "micsource"   # Host side of the adb forward

SNI_WATCHER = "org.kde.StatusNotifierWatcher"
SNI_WATCHER_PATH = "/StatusNotifierWatcher"
SNI_PATH = "/StatusNotifierItem"
SNI_MENU_PATH = "/StatusNotifierItem/menus/micsource"

ICON_NAME = "micsource"
FALLBACK_ICON = "audio-input-microphone"


def _log(msg):
    print(f"[micsource-tray] {msg}", flush=True)


def _append_log(msg):
    """Best-effort append to tray.log (survives GUI-launched processes)."""
    stamp = time.strftime("%Y-%m-%d %H:%M:%S")
    try:
        with open(LOG_PATH, "a") as fh:
            fh.write(f"{stamp} {msg.rstrip(chr(10))}\n")
    except OSError:
        pass


# ----------------------------------------------------------------------
# Pure menu/property model (no gi — unit-tested via fake-`gi` stub import)
# ----------------------------------------------------------------------
ADB_CMD = "adb"
SERIAL = None
HOST_SOCKET = DEFAULT_HOST_SOCKET

ACTION_ITEMS = ("start", "stop", "window", "config", "quit")


def status_name(connected: bool) -> str:
    """User-facing one-word status for the Status menu row."""
    return "connected" if connected else "disconnected"


def tray_icon_name(connected: bool) -> str:
    return ICON_NAME if connected else FALLBACK_ICON


def menu_config(status: str) -> list:
    """Tray menu model; ids / order per the dbusmenu root layout.

    Item 1 is the live status row (disabled = not clickable); item 2 is
    the separator; items 3..7 carry the actions.
    """
    return [
        {"id": 1, "type": "standard",
         "label": f"Status: {status}", "enabled": False},
        {"id": 2, "type": "separator"},
        {"id": 3, "type": "standard", "label": "Start Service",
         "enabled": True, "action": "start"},
        {"id": 4, "type": "standard", "label": "Stop Service",
         "enabled": True, "action": "stop"},
        {"id": 5, "type": "standard", "label": "Open Control Window",
         "enabled": True, "action": "window"},
        {"id": 6, "type": "standard", "label": "Open Config Folder",
         "enabled": True, "action": "config"},
        {"id": 7, "type": "standard", "label": "Quit",
         "enabled": True, "action": "quit"},
    ]


def dbusmenu_props(item: dict) -> dict:
    """dbusmenu property dict for one item (plain values, no gi).

    Separators never carry a label; standard items always carry
    label + enabled; `children-display` is absent on leaf items.
    """
    if item.get("type") == "separator":
        return {"type": "separator", "visible": True}
    props = {"type": "standard",
             "label": item.get("label", ""),
             "enabled": bool(item.get("enabled", True)),
             "visible": True}
    return props


def group_properties(items: list, ids: list) -> dict:
    """{id: props} for the requested ids; missing ids are simply absent."""
    by_id = {item["id"]: dbusmenu_props(item) for item in items}
    return {int(i): by_id[int(i)] for i in (ids or []) if int(i) in by_id}


def build_layout(items: list, revision: int) -> tuple:
    """(revision, root layout) per the dbusmenu GetLayout spec.

    Root is id 0 with `children-display: submenu` and every model item as
    a leaf `(id, props, ())`.
    """
    children = tuple(
        (item["id"], dbusmenu_props(item), ()) for item in items)
    return int(revision), (0, {"children-display": "submenu"}, children)


def sni_props(connected: bool) -> dict:
    """org.kde.StatusNotifierItem property snapshot (plain values)."""
    icon = tray_icon_name(connected)
    return {
        "Category": "ApplicationStatus",
        "Id": APP_ID,
        "Title": APP_TITLE,
        "Status": "Active",
        "WindowId": 0,
        "IconName": icon,
        "ToolTip": {
            "icon_name": icon,
            "icon_pixmap": [],
            "title": APP_TITLE,
            "description": f"phone mic over USB — {status_name(connected)}",
        },
    }


def _load_config():
    """Read adb path, serial and host socket name from config.ini."""
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


# ----------------------------------------------------------------------
# StatusNotifierItem + dbusmenu daemon (pure GLib/Gio; no Gtk, no GIRs)
# ----------------------------------------------------------------------
poll_thread = None


class TrayDaemon:
    """Owns the D-Bus objects and the state visible to the shell."""

    _INTROSPECTION_XML = """
<node>
  <interface name="org.kde.StatusNotifierItem">
    <property name="Category" type="s" access="read"/>
    <property name="Id" type="s" access="read"/>
    <property name="Title" type="s" access="read"/>
    <property name="Status" type="s" access="read"/>
    <property name="WindowId" type="i" access="read"/>
    <property name="IconName" type="s" access="read"/>
    <property name="IconPixmap" type="a(iiay)" access="read"/>
    <property name="OverlayIconName" type="s" access="read"/>
    <property name="AttentionIconName" type="s" access="read"/>
    <property name="AttentionIconPixmap" type="a(iiay)" access="read"/>
    <property name="ToolTip" type="(sa(iiay)ss)" access="read"/>
    <property name="Menu" type="o" access="read"/>
    <property name="ItemIsMenu" type="b" access="read"/>
    <method name="Activate">
      <arg type="i" direction="in"/>
      <arg type="i" direction="in"/>
    </method>
    <method name="SecondaryActivate">
      <arg type="i" direction="in"/>
      <arg type="i" direction="in"/>
    </method>
    <method name="ContextMenu">
      <arg type="i" direction="in"/>
      <arg type="i" direction="in"/>
    </method>
    <method name="Scroll">
      <arg type="i" direction="in"/>
      <arg type="s" direction="in"/>
    </method>
    <signal name="NewTitle"/>
    <signal name="NewIcon"/>
    <signal name="NewAttentionIcon"/>
    <signal name="NewOverlayIcon"/>
    <signal name="NewToolTip"/>
    <signal name="NewStatus">
      <arg type="s"/>
    </signal>
  </interface>
  <interface name="com.canonical.dbusmenu">
    <property name="Version" type="u" access="read"/>
    <property name="TextDirection" type="s" access="read"/>
    <property name="Status" type="s" access="read"/>
    <property name="IconThemePath" type="as" access="read"/>
    <method name="AboutToShow">
      <arg type="i" direction="in"/>
      <arg type="b" direction="out"/>
    </method>
    <method name="GetLayout">
      <arg type="i" direction="in"/>
      <arg type="i" direction="in"/>
      <arg type="as" direction="in"/>
      <arg type="u" direction="out"/>
      <arg type="(ia{sv}av)" direction="out"/>
    </method>
    <method name="GetGroupProperties">
      <arg type="ai" direction="in"/>
      <arg type="as" direction="in"/>
      <arg type="a(ia{sv})" direction="out"/>
    </method>
    <method name="GetProperty">
      <arg type="i" direction="in"/>
      <arg type="s" direction="in"/>
      <arg type="v" direction="out"/>
    </method>
    <method name="Event">
      <arg type="i" direction="in"/>
      <arg type="s" direction="in"/>
      <arg type="v" direction="in"/>
      <arg type="u" direction="in"/>
    </method>
    <method name="EventGroup">
      <arg type="a(isvu)" direction="in"/>
      <arg type="ai" direction="out"/>
    </method>
    <signal name="ItemsPropertiesUpdated">
      <arg type="a(ia{sv})"/>
      <arg type="a(ias)"/>
    </signal>
    <signal name="LayoutUpdated">
      <arg type="u"/>
      <arg type="i"/>
    </signal>
    <signal name="ItemActivationRequested">
      <arg type="i"/>
      <arg type="u"/>
    </signal>
  </interface>
</node>
"""

    def __init__(self, bus):
        self.bus = bus
        self.revision = 1
        self.connected = False
        self.items = menu_config("checking…")
        self.loop = None

    # -- shared variant glue -------------------------------------------
    def _variant_for(self, value):
        if isinstance(value, bool):
            return GLib.Variant("b", value)
        if isinstance(value, int):
            return GLib.Variant("i", value)
        if isinstance(value, list):
            return GLib.Variant("as", value)
        return GLib.Variant("s", str(value))

    def _variant_dict(self, props):
        return {k: self._variant_for(v) for k, v in props.items()}

    def _layout(self):
        """(u (ia{sv}av)) variant for GetLayout / LayoutUpdated.

        Children are a direct `av` third particle (each child a variant
        of the same (ia{sv}av) shape) — that is the signature GNOME Shell
        (and the appindicator clients) expect on the wire.
        """
        def item_variant(item):
            return GLib.Variant("(ia{sv}av)", (
                item["id"],
                self._variant_dict(dbusmenu_props(item)),
                GLib.Variant("av", [])))

        root = (0,
                {"children-display": GLib.Variant("s", "submenu")},
                GLib.Variant("av", [item_variant(item)
                                    for item in self.items]))
        return GLib.Variant("(u(ia{sv}av))", (self.revision, root))

    def _tooltip_var(self):
        tt = sni_props(self.connected)["ToolTip"]
        return GLib.Variant("(sa(iiay)ss)",
                            (tt["icon_name"], [], tt["title"],
                             tt["description"]))

    # -- SNI interface --------------------------------------------------
    def _sni_call(self, conn, sender, path, iface, method, params, inv):
        # Activate / SecondaryActivate / ContextMenu / Scroll: no-ops.
        inv.return_value()

    def _sni_getprop(self, conn, sender, path, iface, name):
        if name == "Menu":
            return GLib.Variant("o", SNI_MENU_PATH)
        if name == "ItemIsMenu":
            return GLib.Variant("b", True)
        if name in ("IconPixmap", "AttentionIconPixmap"):
            return GLib.Variant("a(iiay)", [])
        if name in ("OverlayIconName", "AttentionIconName"):
            return GLib.Variant("s", "")
        if name == "ToolTip":
            return self._tooltip_var()
        return self._variant_for(sni_props(self.connected)[name])

    # -- dbusmenu interface ---------------------------------------------
    def _menu_call(self, conn, sender, path, iface, method, params, inv):
        if method == "GetLayout":
            inv.return_value(self._layout())
        elif method == "GetGroupProperties":
            ids, _names = params.unpack()
            found = group_properties(self.items, list(ids))
            payload = [(mid, self._variant_dict(props))
                       for mid, props in found.items()]
            inv.return_value(GLib.Variant("a(ia{sv})", payload))
        elif method == "GetProperty":
            menu_id, name = params.unpack()
            found = group_properties(self.items, [menu_id])
            value = found.get(int(menu_id), {}).get(name, "")
            inv.return_value(GLib.Variant("v", self._variant_for(value)))
        elif method == "AboutToShow":
            inv.return_value(GLib.Variant("(b)", (False,)))
        elif method == "Event":
            menu_id, event, _data, _ts = params.unpack()
            self._dispatch_event(menu_id, event)
            inv.return_value()
        elif method == "EventGroup":
            events = params.unpack()[0]
            for menu_id, event, _data, _ts in events:
                self._dispatch_event(menu_id, event)
            inv.return_value(GLib.Variant("(ai)", ([],)))
        else:
            inv.return_value()

    def _menu_getprop(self, conn, sender, path, iface, name):
        if name == "Version":
            return GLib.Variant("u", 3)   # dbusmenu protocol version
        if name == "TextDirection":
            return GLib.Variant("s", "ltr")
        if name == "Status":
            return GLib.Variant("s", "normal")
        return GLib.Variant("as", [])     # IconThemePath

    def _dispatch_event(self, menu_id, event):
        if event != "clicked":
            return
        for item in self.items:
            if item["id"] == menu_id:
                if not item.get("enabled", True):
                    return           # disabled / unknown: silently ignored
                self._dispatch_action(item.get("action"))
                return

    def _dispatch_action(self, action):
        _log(f"menu action: {action}")
        if action == "start":
            subprocess.Popen([CLI_PATH, "start"])
        elif action == "stop":
            subprocess.Popen([CLI_PATH, "stop"])
        elif action == "window":
            app_path = os.path.join(DATA_DIR, "micsource-app.py")
            if os.path.isfile(app_path):
                subprocess.Popen(["python3", app_path])
            else:
                _log("control window not installed; run install.sh first")
        elif action == "config":
            subprocess.Popen(["xdg-open", CONFIG_DIR])
        elif action == "quit" and self.loop is not None:
            self.loop.quit()

    # -- lifecycle -------------------------------------------------------
    def export_all(self):
        node = Gio.DBusNodeInfo.new_for_xml(self._INTROSPECTION_XML)
        sni = node.lookup_interface("org.kde.StatusNotifierItem")
        menu = node.lookup_interface("com.canonical.dbusmenu")
        self.bus.register_object(SNI_PATH, sni,
                                 self._sni_call, self._sni_getprop, None)
        self.bus.register_object(SNI_MENU_PATH, menu,
                                 self._menu_call, self._menu_getprop, None)

    def register_with_watcher(self):
        # Register the way every libappindicator app does (telegram,
        # zapzap, easyeffects…): acquire a well-known KDE-style name and
        # register THAT instead of our unique name — the watcher's
        # parser and proxies are keyed on this pattern.
        pid = os.getpid()
        self._sni_name = f"org.kde.StatusNotifierItem-{pid}-1"
        acquired = self.bus.own_name(
            self._sni_name, Gio.BusNameOwnerFlags.NONE,
            lambda *_a: _append_log(f"owned name {self._sni_name}"),
            lambda *_a: _append_log(f"lost name {self._sni_name}"))
        self._name_owner_id = acquired
        try:
            self.bus.call_sync(
                SNI_WATCHER, SNI_WATCHER_PATH, SNI_WATCHER,
                "RegisterStatusNotifierItem",
                GLib.Variant("(s)", (self._sni_name,)),
                None, Gio.DBusCallFlags.NONE, 3000, None)
            _append_log(f"registered item as {self._sni_name} {SNI_PATH}")
            return True
        except GLib.Error as exc:
            _append_log(f"register failed: {exc}")
            return False

    def watch_watcher(self):
        # Re-register when the watcher (extension) returns after a
        # restart/disable — the icon reappears without a tray restart.
        self.bus.signal_subscribe(
            "org.freedesktop.DBus", "org.freedesktop.DBus",
            "NameOwnerChanged", None, SNI_WATCHER,
            Gio.DBusSignalFlags.NONE, self._on_watcher_owner)

    def _on_watcher_owner(self, conn, sender, obj_path, iface, signal,
                          params):
        _name, _old_owner, new_owner = params.unpack()[:3]
        if new_owner:
            if self.register_with_watcher():
                _log("watcher appeared/restarted — re-registered")
        else:
            _append_log("watcher gone — icon hidden until it returns")

    def apply_status(self, connected):
        changed = bool(connected) != self.connected
        self.connected = bool(connected)
        self.items = menu_config(status_name(self.connected))
        self.revision += 1
        # Push menu updates (LayoutUpdated + the Status row's property
        # change) instead of relying on AboutToShow polling.
        self.bus.emit_signal(None, SNI_MENU_PATH, "com.canonical.dbusmenu",
                             "LayoutUpdated",
                             GLib.Variant("(ui)", (self.revision, 0)))
        updated = [(self.items[0]["id"],
                    self._variant_dict(dbusmenu_props(self.items[0])))]
        self.bus.emit_signal(None, SNI_MENU_PATH, "com.canonical.dbusmenu",
                             "ItemsPropertiesUpdated",
                             GLib.Variant("(a(ia{sv})a(ias))",
                                          (updated, [])))
        if changed:
            _append_log(f"status -> {status_name(self.connected)}")
            self.bus.emit_signal(None, SNI_PATH,
                                 "org.kde.StatusNotifierItem",
                                 "NewStatus",
                                 GLib.Variant("(s)", ("Active",)))
            for sig in ("NewIcon", "NewToolTip"):
                self.bus.emit_signal(None, SNI_PATH,
                                     "org.kde.StatusNotifierItem",
                                     sig, GLib.Variant("()"))
        return False   # GLib.idle_add callback: run once

    def _poll_tick(self):
        global poll_thread
        if poll_thread is not None and poll_thread.is_alive():
            return True   # previous poll still running
        def worker():
            try:
                online = device_online()
                forwarded = socket_forwarded() if online else False
                GLib.idle_add(self.apply_status, online and forwarded)
            except Exception as exc:
                _append_log(f"status poll error: {exc}")
        poll_thread = threading.Thread(target=worker, daemon=True)
        poll_thread.start()
        return True       # keep the timer

    def run(self):
        self.export_all()
        self.watch_watcher()
        if not self.register_with_watcher():
            msg = ("no StatusNotifier watcher on the session bus — "
                   "tray unavailable")
            print(f"[micsource-tray] {msg}", flush=True)
            raise SystemExit(1)
        self.loop = GLib.MainLoop()
        GLib.timeout_add_seconds(3, self._poll_tick)
        self._poll_tick()      # immediate first status refresh
        self.loop.run()


def main():
    _append_log(f"start (pure dbus tray) argv={sys.argv[1:]!r}")
    _load_config()
    bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
    TrayDaemon(bus).run()


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
    except SystemExit:
        raise
    except Exception as exc:
        _append_log(f"fatal: {exc}")
        raise SystemExit(1)
