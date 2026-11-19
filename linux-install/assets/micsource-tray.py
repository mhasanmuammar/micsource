#!/usr/bin/env python3
"""
MicSource StatusNotifierItem tray client (PyGObject / GLib/Gio).

Persistent tray icon that:
  * shows connection state to the Android device via adb,
  * offers Start / Stop Service (the background service is the only
    audio pump; the tray itself never streams),
  * opens the control window and the config folder,
  * exports a dbusmenu menu and quits cleanly.

The tray is a status and control surface; audio streaming belongs to the
background monitor service.
"""
import configparser
import os
import subprocess
import threading
import time

try:
    from gi.repository import GLib, Gio
except Exception as exc:  # PyGObject without GLib/Gio
    _logf = os.path.join(
        os.path.expanduser("~/.local/share/micsource"), "tray.log")
    try:
        with open(_logf, "a") as fh:
            fh.write(f"PyGObject GLib/Gio unavailable: {exc}\n")
    except OSError:
        pass
    print(f"[micsource-tray] PyGObject (GLib/Gio) unavailable: {exc}", flush=True)
    raise SystemExit(1)

APP_ID = "micsource"
APP_TITLE = "MicSource"
DATA_DIR = os.path.expanduser("~/.local/share/micsource")
CONFIG_DIR = os.path.expanduser("~/.config/micsource")
CONFIG_PATH = os.path.join(CONFIG_DIR, "config.ini")
ADB_PATH_FILE = os.path.join(DATA_DIR, "adb.path")
CLI_PATH = os.path.join(DATA_DIR, "micsource")

ANDROID_PKG = "fr.dzx.audiosource"  # Android package (baked into the APK)
DEVICE_SOCKET = "audiosource"       # Device-side socket (RecordThread)
DEFAULT_HOST_SOCKET = "micsource"   # Host side of the adb forward

ICON_NAME = "micsource"
FALLBACK_ICON = "audio-input-microphone"
SNI_PATH = "/StatusNotifierItem"
SNI_MENU_PATH = "/StatusNotifierItem/menus/micsource"
SNI_INTERFACE = "org.kde.StatusNotifierItem"
MENU_INTERFACE = "com.canonical.dbusmenu"
WATCHER_NAME = "org.kde.StatusNotifierWatcher"
WATCHER_PATH = "/StatusNotifierWatcher"
WATCHER_INTERFACE = "org.kde.StatusNotifierWatcher"

poll_thread = None
daemon = None

ADB_CMD = "adb"
SERIAL = None
HOST_SOCKET = DEFAULT_HOST_SOCKET


def status_name(connected):
    return "connected" if connected else "disconnected"


def tray_icon_name(connected):
    return ICON_NAME if connected else FALLBACK_ICON


def menu_config(status):
    return [
        {"id": 1, "type": "standard", "label": f"Status: {status}",
         "enabled": False},
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


def dbusmenu_props(item):
    props = {"type": item.get("type", "standard"),
             "enabled": bool(item.get("enabled", True)),
             "visible": bool(item.get("visible", True))}
    if item.get("type") != "separator" and "label" in item:
        props["label"] = item["label"]
    if item.get("children-display"):
        props["children-display"] = item["children-display"]
    return props


def build_layout(items, revision):
    children = [(item["id"], dbusmenu_props(item), []) for item in items]
    return revision, (0, {"children-display": "submenu"}, children)


def group_properties(items, ids, property_names=None):
    if not ids:
        ids = [item["id"] for item in items]
    wanted = set(property_names or [])
    found = {}
    for item in items:
        if item["id"] not in ids:
            continue
        props = dbusmenu_props(item)
        if wanted:
            props = {key: value for key, value in props.items()
                     if key in wanted}
        found[item["id"]] = props
    return found


def sni_props(connected):
    icon = tray_icon_name(connected)
    state = status_name(connected)
    return {
        "Category": "ApplicationStatus",
        "Id": APP_ID,
        "Title": APP_TITLE,
        "Status": "Active",
        "WindowId": 0,
        "IconName": icon,
        "IconPixmap": [],
        "OverlayIconName": "",
        "OverlayIconPixmap": [],
        "AttentionIconName": "",
        "AttentionIconPixmap": [],
        "AttentionMovieName": "",
        "ToolTip": (icon, [], APP_TITLE, state.capitalize()),
        "ItemIsMenu": True,
        "Menu": SNI_MENU_PATH,
    }


SNI_XML = """
<node><interface name="org.kde.StatusNotifierItem">
<property name="Category" type="s" access="read"/>
<property name="Id" type="s" access="read"/>
<property name="Title" type="s" access="read"/>
<property name="Status" type="s" access="read"/>
<property name="WindowId" type="u" access="read"/>
<property name="IconName" type="s" access="read"/>
<property name="IconPixmap" type="a(iiay)" access="read"/>
<property name="OverlayIconName" type="s" access="read"/>
<property name="OverlayIconPixmap" type="a(iiay)" access="read"/>
<property name="AttentionIconName" type="s" access="read"/>
<property name="AttentionIconPixmap" type="a(iiay)" access="read"/>
<property name="AttentionMovieName" type="s" access="read"/>
<property name="ToolTip" type="(sa(iiay)ss)" access="read"/>
<property name="ItemIsMenu" type="b" access="read"/>
<property name="Menu" type="o" access="read"/>
<method name="ContextMenu"><arg type="i" direction="in"/><arg type="i" direction="in"/></method>
<method name="Activate"><arg type="i" direction="in"/><arg type="i" direction="in"/></method>
<method name="SecondaryActivate"><arg type="i" direction="in"/><arg type="i" direction="in"/></method>
<method name="Scroll"><arg type="i" direction="in"/><arg type="s" direction="in"/></method>
<signal name="NewTitle"/><signal name="NewIcon"/>
<signal name="NewAttentionIcon"/><signal name="NewOverlayIcon"/>
<signal name="NewToolTip"/><signal name="NewStatus"><arg type="s"/></signal>
</interface></node>
"""

MENU_XML = """
<node><interface name="com.canonical.dbusmenu">
<property name="Version" type="u" access="read"/>
<property name="TextDirection" type="s" access="read"/>
<property name="Status" type="s" access="read"/>
<property name="IconThemePath" type="as" access="read"/>
<method name="GetLayout"><arg type="i" direction="in"/><arg type="i" direction="in"/><arg type="as" direction="in"/><arg type="u" direction="out"/><arg type="(ia{sv}av)" direction="out"/></method>
<method name="GetGroupProperties"><arg type="ai" direction="in"/><arg type="as" direction="in"/><arg type="a(ia{sv})" direction="out"/></method>
<method name="GetProperty"><arg type="i" direction="in"/><arg type="s" direction="in"/><arg type="v" direction="out"/></method>
<method name="Event"><arg type="i" direction="in"/><arg type="s" direction="in"/><arg type="v" direction="in"/><arg type="u" direction="in"/></method>
<method name="EventGroup"><arg type="a(isvu)" direction="in"/><arg type="ai" direction="out"/></method>
<method name="AboutToShow"><arg type="i" direction="in"/><arg type="b" direction="out"/></method>
<method name="AboutToShowGroup"><arg type="ai" direction="in"/><arg type="ai" direction="out"/><arg type="ai" direction="out"/></method>
<signal name="ItemsPropertiesUpdated"><arg type="a(ia{sv})"/><arg type="a(ias)"/></signal>
<signal name="LayoutUpdated"><arg type="u"/><arg type="i"/></signal>
<signal name="ItemActivationRequested"><arg type="i"/><arg type="u"/></signal>
</interface></node>
"""

# Gtk/AppIndicator is deliberately not imported. Gio is part of PyGObject,
# which the control window already requires; watcher presence is a desktop
# capability check performed by the preferences toggle.


def _log(msg):
    print(f"[micsource-tray] {msg}", flush=True)


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


def ensure_forward():
    """(Re)establish the host/socket forward. Returns (ok, stderr)."""
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


def start_monitoring():
    """Start the background service — it is the only audio pump."""
    subprocess.Popen([CLI_PATH, "start"])


def stop_monitoring():
    """Stop the background service (which stops monitoring)."""
    subprocess.Popen([CLI_PATH, "stop"])


_SNI_VARIANTS = {
    "Category": "s", "Id": "s", "Title": "s", "Status": "s",
    "WindowId": "u", "IconName": "s", "IconPixmap": "a(iiay)",
    "OverlayIconName": "s", "OverlayIconPixmap": "a(iiay)",
    "AttentionIconName": "s", "AttentionIconPixmap": "a(iiay)",
    "AttentionMovieName": "s", "ToolTip": "(sa(iiay)ss)",
    "ItemIsMenu": "b", "Menu": "o",
}
_MENU_VARIANTS = {
    "type": "s", "label": "s", "enabled": "b", "visible": "b",
    "children-display": "s",
}


def _variant_properties(properties):
    return {key: GLib.Variant(_MENU_VARIANTS[key], value)
            for key, value in properties.items() if key in _MENU_VARIANTS}


def _layout_variant(node, property_names=None, depth=0):
    item_id, properties, children = node
    wanted = set(property_names or [])
    if wanted:
        properties = {key: value for key, value in properties.items()
                      if key in wanted}
    child_nodes = []
    if depth != 0:
        child_depth = depth - 1 if depth > 0 else -1
        for child in children:
            child_nodes.append(GLib.Variant(
                "v", _layout_variant(child, property_names, child_depth)))
    return GLib.Variant("(ia{sv}av)",
                        (item_id, _variant_properties(properties), child_nodes))


class TrayDaemon:
    def __init__(self, bus):
        self.bus = bus
        self.loop = GLib.MainLoop.new(None, False)
        self.connected = False
        self.revision = 1
        self.sni_properties = sni_props(False)
        self.menu_items = menu_config("disconnected")
        self.registrations = []
        self.watcher_subscription = 0
        self.poll_thread = None
        self.watcher_owner = ""

    def export_all(self):
        sni_node = Gio.DBusNodeInfo.new_for_xml(SNI_XML)
        menu_node = Gio.DBusNodeInfo.new_for_xml(MENU_XML)
        self.registrations.append(self.bus.register_object(
            SNI_PATH, sni_node.lookup_interface(SNI_INTERFACE),
            self._method_call, self._get_property, None))
        self.registrations.append(self.bus.register_object(
            SNI_MENU_PATH, menu_node.lookup_interface(MENU_INTERFACE),
            self._method_call, self._get_property, None))

    def register_with_watcher(self):
        try:
            self.bus.call_sync(
                WATCHER_NAME, WATCHER_PATH, WATCHER_INTERFACE,
                "RegisterStatusNotifierItem",
                GLib.Variant("(s)", (self.bus.get_unique_name(),)),
                None, Gio.DBusCallFlags.NONE, 3000, None)
            self.watcher_owner = WATCHER_NAME
            _log("registered with StatusNotifierWatcher")
            return True
        except GLib.Error as exc:
            _log(f"StatusNotifierWatcher registration failed: {exc}")
            return False

    def watch_watcher(self):
        self.watcher_subscription = self.bus.signal_subscribe(
            "org.freedesktop.DBus", "org.freedesktop.DBus",
            "NameOwnerChanged", "/org/freedesktop/DBus",
            WATCHER_NAME, Gio.DBusSignalFlags.NONE,
            self._watcher_changed, None)

    def _watcher_changed(self, _bus, _sender, _path, _interface, _signal,
                         parameters, _data):
        name, old_owner, new_owner = parameters.unpack()
        if name != WATCHER_NAME:
            return
        if old_owner:
            self.watcher_owner = ""
        if new_owner and new_owner != old_owner:
            self.register_with_watcher()

    def _get_property(self, _bus, _sender, object_path, _interface, name):
        if object_path == SNI_PATH:
            value = self.sni_properties[name]
            return GLib.Variant(_SNI_VARIANTS[name], value)
        menu_values = {
            "Version": ("u", 3),
            "TextDirection": ("s", "ltr"),
            "Status": ("s", "normal"),
            "IconThemePath": ("as", []),
        }
        signature, value = menu_values[name]
        return GLib.Variant(signature, value)

    def _return(self, invocation, signature, value):
        invocation.return_value(GLib.Variant(signature, value))

    def _method_call(self, _bus, _sender, object_path, interface, method,
                     parameters, invocation):
        if interface == SNI_INTERFACE:
            if method == "Activate":
                self._dispatch_action("window")
            invocation.return_value(GLib.Variant("()", ()))
            return
        if interface != MENU_INTERFACE:
            invocation.return_dbus_error(
                "org.freedesktop.DBus.Error.UnknownMethod", method)
            return

        items_by_id = {item["id"]: item for item in self.menu_items}
        if method == "GetLayout":
            parent_id, depth, names = parameters.unpack()
            _, root = build_layout(self.menu_items, self.revision)
            node = root if parent_id == 0 else next(
                ((item["id"], dbusmenu_props(item), [])
                 for item in self.menu_items if item["id"] == parent_id),
                (parent_id, {}, []))
            invocation.return_value(GLib.Variant.new_tuple(
                GLib.Variant("u", self.revision),
                _layout_variant(node, names, depth)))
        elif method == "GetGroupProperties":
            ids, names = parameters.unpack()
            found = group_properties(self.menu_items, ids, names)
            result = [(item_id, _variant_properties(props))
                      for item_id, props in found.items()]
            self._return(invocation, "(a(ia{sv}))", (result,))
        elif method == "GetProperty":
            item_id, name = parameters.unpack()
            item = items_by_id.get(item_id)
            if item is None or name not in dbusmenu_props(item):
                invocation.return_dbus_error(
                    "com.canonical.dbusmenu.Error.InvalidItem",
                    f"no menu property {name!r} for item {item_id}")
                return
            value = dbusmenu_props(item)[name]
            self._return(invocation, "(v)",
                         (GLib.Variant(_MENU_VARIANTS[name], value),))
        elif method == "Event":
            item_id, event_id, _data, _timestamp = parameters.unpack()
            self._menu_event(item_id, event_id)
            invocation.return_value(GLib.Variant("()", ()))
        elif method == "EventGroup":
            events, = parameters.unpack()
            errors = [item_id for item_id, event_id, _data, _stamp in events
                      if not self._menu_event(item_id, event_id)]
            self._return(invocation, "(ai)", (errors,))
        elif method == "AboutToShow":
            self._return(invocation, "(b)", (False,))
        elif method == "AboutToShowGroup":
            (ids,) = parameters.unpack()
            errors = [item_id for item_id in ids if item_id not in items_by_id]
            self._return(invocation, "(aiai)", ([], errors))
        else:
            invocation.return_dbus_error(
                "org.freedesktop.DBus.Error.UnknownMethod", method)

    def _menu_event(self, item_id, event_id):
        item = next((it for it in self.menu_items if it["id"] == item_id), None)
        if event_id != "clicked" or item is None or not item.get("enabled", True):
            return False
        action = item.get("action")
        if action:
            self._dispatch_action(action)
        return True

    def _dispatch_action(self, action):
        try:
            if action in ("start", "stop"):
                subprocess.Popen([CLI_PATH, action])
            elif action == "window":
                app_path = os.path.join(DATA_DIR, "micsource-app.py")
                if os.path.isfile(app_path):
                    subprocess.Popen(["python3", app_path])
                else:
                    _log("control window not installed; run install.sh first")
            elif action == "config":
                subprocess.Popen(["xdg-open", CONFIG_DIR])
            elif action == "quit":
                self.loop.quit()
        except OSError as exc:
            _log(f"could not run tray action {action}: {exc}")

    def _emit(self, object_path, interface, signal, signature="()", value=()):
        try:
            self.bus.emit_signal(None, object_path, interface, signal,
                                 GLib.Variant(signature, value))
        except GLib.Error as exc:
            _log(f"could not emit {signal}: {exc}")

    def apply_status(self, connected):
        if self.connected == connected:
            return False
        self.connected = connected
        self.sni_properties = sni_props(connected)
        self.menu_items = menu_config(status_name(connected))
        self.revision += 1
        self._emit(SNI_PATH, SNI_INTERFACE, "NewIcon")
        self._emit(SNI_PATH, SNI_INTERFACE, "NewToolTip")
        self._emit(SNI_PATH, SNI_INTERFACE, "NewStatus", "(s)", ("Active",))
        self._emit(SNI_MENU_PATH, MENU_INTERFACE, "LayoutUpdated", "(ui)",
                   (self.revision, 0))
        status_props = _variant_properties(dbusmenu_props(self.menu_items[0]))
        self._emit(SNI_MENU_PATH, MENU_INTERFACE, "ItemsPropertiesUpdated",
                   "(a(ia{sv})a(ias))", ([(1, status_props)], []))
        return False

    def poll_status(self):
        if self.poll_thread is not None and self.poll_thread.is_alive():
            return True

        def worker():
            try:
                online = device_online()
                forwarded = socket_forwarded() if online else False
                GLib.idle_add(self.apply_status, online and forwarded)
            except Exception as exc:
                _log(f"status poll error: {exc}")

        self.poll_thread = threading.Thread(target=worker, daemon=True)
        self.poll_thread.start()
        return True

    def run(self):
        self.export_all()
        self.watch_watcher()
        if not self.register_with_watcher():
            self._log_failure("No StatusNotifierWatcher is running on the session bus.")
            raise SystemExit(1)
        GLib.timeout_add_seconds(3, self.poll_status)
        self.loop.run()

    @staticmethod
    def _log_failure(message):
        _log(message)
        try:
            with open(os.path.join(DATA_DIR, "tray.log"), "a") as fh:
                fh.write(message + "\n")
        except OSError:
            pass


def main():
    global daemon
    _load_config()
    bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
    daemon = TrayDaemon(bus)
    daemon.run()


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
    except Exception as exc:
        _log(f"fatal: {exc}")
        raise SystemExit(1)
