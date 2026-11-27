"""XDG / Flatpak path resolution for MicSource.

Every component (GUI, CLI, tray, monitor) resolves its state through this
module so the host install and the Flatpak sandbox never share data,
configuration, logs or an ADB server port by accident.

The host installer keeps its historical layout because the XDG defaults are
exactly those historical paths (~/.local/share/micsource, ~/.config/micsource,
~/.local/state/micsource).  Inside the Flatpak, XDG_DATA_HOME et al. are
already redirected to ~/.var/app/<id>/, so the same code lands in the
sandbox automatically.
"""
import os

APP_ID = "io.github.mhasanmuammar.MicSource"
IS_FLATPAK = bool(os.environ.get("FLATPAK_ID"))
FLATPAK_ID = os.environ.get("FLATPAK_ID", "")

EXT_ID = "micsource-tile@micsource.local"

HOME = os.path.expanduser("~")
UID = os.getuid()


def _base_dir(var, default):
    value = os.environ.get(var, "").strip()
    if value:
        return os.path.abspath(os.path.expanduser(value))
    return default


def _env_path(var, default):
    value = os.environ.get(var, "").strip()
    if value:
        return os.path.abspath(os.path.expanduser(value))
    return default


DATA_HOME = _base_dir("XDG_DATA_HOME", os.path.join(HOME, ".local", "share"))
CONFIG_HOME = _base_dir("XDG_CONFIG_HOME", os.path.join(HOME, ".config"))
STATE_HOME = _base_dir("XDG_STATE_HOME", os.path.join(HOME, ".local", "state"))
CACHE_HOME = _base_dir("XDG_CACHE_HOME", os.path.join(HOME, ".cache"))
RUNTIME_BASE = _base_dir("XDG_RUNTIME_DIR",
                         os.path.join("/run/user", str(UID)))

DATA_DIR = _env_path("MICSOURCE_DATA_DIR",
                     os.path.join(DATA_HOME, "micsource"))
CONFIG_DIR = _env_path("MICSOURCE_CONFIG_DIR",
                       os.path.join(CONFIG_HOME, "micsource"))
STATE_DIR = _env_path("MICSOURCE_STATE_DIR",
                      os.path.join(STATE_HOME, "micsource"))
RUNTIME_DIR = _env_path("MICSOURCE_RUNTIME_DIR",
                        os.path.join(RUNTIME_BASE, "micsource"))
CACHE_DIR = _env_path("MICSOURCE_CACHE_DIR",
                      os.path.join(CACHE_HOME, "micsource"))

if IS_FLATPAK:
    # Keep adb's RSA keys inside the sandbox. The GUI wrapper exports this
    # too, but the CLI (`flatpak run --command=micsource`) and the monitor
    # must agree on the same key store.
    os.environ.setdefault("ANDROID_USER_HOME",
                          os.path.join(DATA_DIR, "android"))
    os.environ.setdefault("MICSOURCE_ADB_SERVER_PORT", "5039")

CONFIG_PATH = os.path.join(CONFIG_DIR, "config.ini")
ADB_PATH_FILE = os.path.join(DATA_DIR, "adb.path")
# Control socket lives with the rest of the private sandbox state; the
# session runtime dir is wiped on logout and cannot outlive a monitor that
# the app intentionally keeps running.
CONTROL_SOCKET = os.path.join(DATA_DIR, "micsource.sock")

# Default ADB server port.  The Flatpak wrapper exports
# MICSOURCE_ADB_SERVER_PORT=5039 before this module is imported.
try:
    ADB_SERVER_PORT = int(os.environ.get("MICSOURCE_ADB_SERVER_PORT", "5038"))
except ValueError:
    ADB_SERVER_PORT = 5038

if IS_FLATPAK:
    APP_PATH = "/app/lib/micsource/micsource-app.py"
    CLI_PATH = "/app/bin/micsource"
    TRAY_PATH = "/app/lib/micsource/micsource-tray.py"
    MONITOR_PATH = "/app/lib/micsource/micsource-monitor.py"
    GUI_PATH = "/app/bin/micsource-gui"
    GNOME_EXT_SRC = "/app/share/micsource/gnome"
    ICON_NAME = APP_ID
else:
    APP_PATH = os.path.join(DATA_DIR, "micsource-app.py")
    CLI_PATH = os.path.join(DATA_DIR, "micsource")
    TRAY_PATH = os.path.join(DATA_DIR, "micsource-tray.py")
    MONITOR_PATH = os.path.join(DATA_DIR, "micsource-monitor.py")
    GUI_PATH = os.path.join(DATA_DIR, "micsource-gui")
    GNOME_EXT_SRC = os.path.join(DATA_DIR, "gnome")
    ICON_NAME = "micsource"

SYSTEMD_UNIT = "micsource.service"
UNIT_FILE = os.path.join(CONFIG_HOME, "systemd", "user", SYSTEMD_UNIT)

TRAY_DESKTOP = os.path.join(CONFIG_HOME, "autostart",
                            "micsource-tray.desktop")

# Host extension directory: mounted by --filesystem=xdg-data/... in the
# Flatpak.  Use $HOME (not XDG_DATA_HOME) because the sandbox redirects
# XDG_DATA_HOME into ~/.var/app while the host path stays at $HOME.
GNOME_EXT_DIR = os.path.join(HOME, ".local", "share", "gnome-shell",
                             "extensions", EXT_ID)
