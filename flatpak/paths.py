"""XDG path resolution for MicSource.

Reads environment variables set by the Flatpak wrapper; falls back to legacy
paths when unset so the host install (install.sh) keeps working.
"""
import os

LEGACY_DATA_DIR = os.path.expanduser("~/.local/share/micsource")
LEGACY_CONFIG_DIR = os.path.expanduser("~/.config/micsource")
LEGACY_STATE_DIR = os.path.expanduser("~/.local/state/micsource")
LEGACY_RUNTIME_DIR = os.path.expanduser("/run/user/%d/micsource" % os.getuid())


def _env_path(var, default):
    value = os.environ.get(var, "").strip()
    if value:
        return os.path.abspath(os.path.expanduser(value))
    return default


DATA_DIR = _env_path("MICSOURCE_DATA_DIR", LEGACY_DATA_DIR)
CONFIG_DIR = _env_path("MICSOURCE_CONFIG_DIR", LEGACY_CONFIG_DIR)
STATE_DIR = _env_path("MICSOURCE_STATE_DIR", LEGACY_STATE_DIR)
RUNTIME_DIR = _env_path("MICSOURCE_RUNTIME_DIR", LEGACY_RUNTIME_DIR)

CONFIG_PATH = os.path.join(CONFIG_DIR, "config.ini")
ADB_PATH_FILE = os.path.join(DATA_DIR, "adb.path")
CONTROL_SOCKET = os.path.join(DATA_DIR, "micsource.sock")
TRAY_PATH = os.path.join(DATA_DIR, "micsource-tray.py")
TRAY_DESKTOP = os.path.expanduser("~/.config/autostart/micsource-tray.desktop")
SYSTEMD_UNIT = "micsource.service"
UNIT_FILE = os.path.expanduser(
    "~/.config/systemd/user/{}".format(SYSTEMD_UNIT)
)
CLI_PATH = os.path.join(DATA_DIR, "micsource")
MONITOR_PATH = os.path.join(DATA_DIR, "micsource-monitor.py")
GUI_PATH = os.path.join(DATA_DIR, "micsource-gui")

for _d in (DATA_DIR, CONFIG_DIR, STATE_DIR, RUNTIME_DIR):
    os.makedirs(_d, exist_ok=True)
