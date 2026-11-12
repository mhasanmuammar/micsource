#!/usr/bin/env python3
"""
MicSource system tray icon (PyGObject / AppIndicator3).

Persistent tray icon that:
  * shows connection state to the Android device via adb,
  * offers Start / Stop Service (the background service is the only
    audio pump; the tray itself never streams),
  * opens the control window and the config folder,
  * quits cleanly.

Audio flow (adb): device RecordService listens on abstract socket
"audiosource"; host runs `adb forward localabstract:micsource localabstract:
audiosource`, and this script connects to the host-side abstract socket
"micsource" and pipes the PCM data to a player.
"""
import configparser
import os
import socket
import subprocess
import threading
import time

import gi

# Gtk 3 + any appindicator client binding. libappindicator is deprecated;
# most distros now package the maintained ayatana fork, so try the classic
# binding first and alias the ayatana one to AppIndicator3 (same API).
try:
    gi.require_version("Gtk", "3.0")
    from gi.repository import Gtk, GLib  # noqa: E402
    try:
        gi.require_version("AppIndicator3", "0.1")
        from gi.repository import AppIndicator3  # noqa: E402,F401
    except (ImportError, ValueError):
        gi.require_version("AyatanaAppIndicator3", "0.1")
        from gi.repository import AyatanaAppIndicator3 as AppIndicator3  # noqa
except Exception as exc:  # Gtk 3 / PyGObject / no appindicator binding
    # Do NOT fall back to the control window here: an explicit tray
    # launch must never silently become a second app window (user
    # report: toggling the tray preference spawned a window). Log the
    # missing-binding error and exit so the preferences toggle can
    # surface it instead.
    _logf = os.path.join(
        os.path.expanduser("~/.local/share/micsource"), "tray.log")
    try:
        with open(_logf, "a") as fh:
            fh.write(f"tray indicator unavailable: {exc}\n")
    except OSError:
        pass
    print(f"[micsource-tray] tray indicator unavailable ({exc})", flush=True)
    print("[micsource-tray] install gir1.2-gtk-3.0 and "
          "gir1.2-ayatanaappindicator3-0.1 (see README)", flush=True)
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

indicator = None
item_status = None
poll_thread = None

ADB_CMD = "adb"
SERIAL = None
HOST_SOCKET = DEFAULT_HOST_SOCKET


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


def update_indicator(connected):
    if indicator is None:
        return
    if connected:
        indicator.set_icon(ICON_NAME)
        indicator.set_label(f"{APP_TITLE} • connected", "")
    else:
        indicator.set_icon(FALLBACK_ICON)
        indicator.set_label(f"{APP_TITLE} • disconnected", "")


def _apply_status(connected):
    """Update status menu item + indicator (runs on the Gtk main thread)."""
    global item_status
    if item_status is not None:
        if connected:
            item_status.set_label("Status: connected")
            item_status.set_tooltip_text("Android device connected & socket forwarded")
        else:
            item_status.set_label("Status: disconnected")
            item_status.set_tooltip_text("No device / socket not forwarded")
    update_indicator(connected)
    return False  # remove this GLib idle callback


def _poll_status():
    """Trigger status refresh in a background thread every cycle."""
    global poll_thread
    if poll_thread is not None and poll_thread.is_alive():
        return True  # keep the timer
    def worker():
        try:
            online = device_online()
            forwarded = socket_forwarded() if online else False
            GLib.idle_add(_apply_status, online and forwarded)
        except Exception as exc:
            _log(f"status poll error: {exc}")
    poll_thread = threading.Thread(target=worker, daemon=True)
    poll_thread.start()
    return True  # keep the timer


def start_monitoring():
    """Start the background service — it is the only audio pump."""
    subprocess.Popen([CLI_PATH, "start"])


def stop_monitoring():
    """Stop the background service (which stops monitoring)."""
    subprocess.Popen([CLI_PATH, "stop"])


def _build_menu():
    global item_status
    menu = Gtk.Menu()

    item_status = Gtk.MenuItem.new_with_label("Status: checking…")
    item_status.set_sensitive(False)
    menu.append(item_status)

    menu.append(Gtk.SeparatorMenuItem())

    item_start = Gtk.MenuItem.new_with_label("Start Service")
    item_stop = Gtk.MenuItem.new_with_label("Stop Service")
    item_window = Gtk.MenuItem.new_with_label("Open Control Window")
    item_conf = Gtk.MenuItem.new_with_label("Open Config Folder")
    item_quit = Gtk.MenuItem.new_with_label("Quit")

    def on_start(_w):
        start_monitoring()

    def on_stop(_w):
        stop_monitoring()

    def on_window(_w):
        app_path = os.path.join(DATA_DIR, "micsource-app.py")
        if os.path.isfile(app_path):
            subprocess.Popen(["python3", app_path])
        else:
            _log("control window not installed; run install.sh first")

    def on_conf(_w):
        subprocess.Popen(["xdg-open", CONFIG_DIR])

    def on_quit(_w):
        Gtk.main_quit()

    item_start.connect("activate", on_start)
    item_stop.connect("activate", on_stop)
    item_window.connect("activate", on_window)
    item_conf.connect("activate", on_conf)
    item_quit.connect("activate", on_quit)

    for it in (item_start, item_stop, item_window, item_conf, item_quit):
        menu.append(it)

    menu.show_all()
    indicator.set_menu(menu)


def main():
    global indicator
    _load_config()

    indicator = AppIndicator3.Indicator.new(
        APP_ID,
        ICON_NAME,
        AppIndicator3.IndicatorCategory.APPLICATION_STATUS,
    )
    indicator.set_status(AppIndicator3.IndicatorStatus.ACTIVE)
    indicator.set_icon(FALLBACK_ICON)
    indicator.set_title(APP_TITLE)
    indicator.set_label(APP_TITLE, "")

    _build_menu()

    # Poll status every 3 seconds (in background; UI never blocks).
    GLib.timeout_add_seconds(3, _poll_status)

    Gtk.main()


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
    except Exception as exc:
        _log(f"fatal: {exc}")
        raise SystemExit(1)
