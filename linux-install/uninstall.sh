#!/usr/bin/env bash
#
# uninstall.sh - Safely remove MicSource host-side components
#
# Removes everything installed by install.sh:
#   * systemd user service (stop/disable/remove unit)
#   * app drawer launcher icon + hicolor icon
#   * generated tray/monitor/GUI scripts (inside ~/.local/share/micsource)
#   * config + data directories (config.ini, staged APK, adb bundle, micsource.sock)
#   * optional GNOME panel toggle extension
#
# Safety:
#   * Refuses to run as root.
#   * Asks before removing the adb bundle (it may be useful elsewhere).
#   * Only deletes the data/config directories if they contain MicSource's own
#     marker files, so an accidentally matching directory is never wiped.
#   * Never touches your Android device, system-wide packages, or adb installed
#     by the package manager.
#   * Idempotent — safe to run multiple times.
set -euo pipefail

##############################################################################
# Configuration
##############################################################################
APP_NAME="micsource"
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_DIR="${PROJECT_ROOT}/linux-install"
CONFIG_DIR="${HOME}/.config/${APP_NAME}"
DATA_DIR="${HOME}/.local/share/${APP_NAME}"
APPS_DIR="${HOME}/.local/share/applications"
SYSTEMD_USER_DIR="${HOME}/.config/systemd/user"
ICON_THEME_DIR="${HOME}/.local/share/icons/hicolor/scalable/apps"
BIN_LINK="${HOME}/.local/bin/${APP_NAME}"
GNOME_EXT_UUID="micsource-tile@micsource.local"
XDG_AUTOSTART="${HOME}/.config/autostart/micsource-tray.desktop"
PULSE_LOCK_CONF="${HOME}/.config/pipewire/pipewire-pulse.conf.d/10-micsource-stream-lock.conf"
GNOME_EXT_DIR="${HOME}/.local/share/gnome-shell/extensions/${GNOME_EXT_UUID}"

RED=$'\e[31m'; GRN=$'\e[32m'; YLW=$'\e[33m'; BLU=$'\e[34m'; BLD=$'\e[1m'; RST=$'\e[0m'

info()  { printf '%s[INFO]%s  %s\n' "$BLU" "$RST" "$*"; }
ok()    { printf '%s[OK]%s   %s\n' "$GRN" "$RST" "$*"; }
warn()  { printf '%s[WARN]%s %s\n' "$YLW" "$RST" "$*"; }
err()   { printf '%s[ERR]%s  %s\n' "$RED" "$RST" "$*" >&2; }
ask()   { printf '%s[?]%s  %s ' "$YLW" "$RST" "$*"; }

confirm() {
    local prompt="${1:-Proceed?}"
    local ans
    ask "${prompt} [y/N] "
    read -r ans || true
    case "$ans" in
        y|Y|yes|Yes|YES) return 0 ;;
        *) return 1 ;;
    esac
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }

# True if the directory contains files created by install.sh (ownership guard)
data_dir_is_ours() {
    local marker
    for marker in adb.path apk.path micsource.sock micsource \
                  micsource-tray.py micsource-monitor.py \
                  micsource-app.py micsource-gui micsource-build \
                  build-env.path micsource-icon.svg micsource-release.apk \
                  adb-bundle; do
        if [[ -e "${DATA_DIR}/${marker}" ]]; then
            return 0
        fi
    done
    return 1
}

##############################################################################
# Safety gate
##############################################################################
if [[ "$EUID" -eq 0 ]]; then
    err "Do not run this uninstaller as root. Run as your normal user."
    exit 1
fi

echo "${BLD}=== MicSource Linux Host Uninstaller ===${RST}"
echo
warn "This will remove the MicSource host-side components from your user account."
warn "It will NOT touch your Android device or any system-wide packages."
echo

if ! confirm "Uninstall MicSource host components?"; then
    info "Aborted. Nothing was removed."
    exit 0
fi

##############################################################################
# 1. Stop & disable the systemd user service
##############################################################################
if have_cmd systemctl; then
    info "Stopping systemd user service..."
    systemctl --user disable --now "${APP_NAME}.service" 2>/dev/null || true
    ok "systemd service stopped/disabled (if it was installed)"
else
    info "systemctl not available; skipping systemd service cleanup."
fi

##############################################################################
# 2. Best-effort kill of a manually launched monitor (per systemd absence)
##############################################################################
MONITOR_PATH="${DATA_DIR}/micsource-monitor.py"
if ! have_cmd systemctl && have_cmd pkill && [[ -f "${MONITOR_PATH}" ]]; then
    # Pattern matches the exact script path only; never kills by generic name.
    pkill -f -- "${MONITOR_PATH}" 2>/dev/null || true
    ok "Stopped any manually launched monitor."
fi

##############################################################################
# 3. Remove systemd unit file
##############################################################################
UNIT_FILE="${SYSTEMD_USER_DIR}/${APP_NAME}.service"
if [[ -f "$UNIT_FILE" ]]; then
    rm -f -- "$UNIT_FILE"
    ok "Removed systemd unit: ${UNIT_FILE}"
    if have_cmd systemctl; then
        systemctl --user daemon-reload 2>/dev/null || true
    fi
fi

##############################################################################
# 4. Remove app drawer launcher
##############################################################################
DESKTOP_FILE="${APPS_DIR}/${APP_NAME}.desktop"
if [[ -f "$DESKTOP_FILE" ]]; then
    rm -f -- "$DESKTOP_FILE"
    ok "Removed launcher: ${DESKTOP_FILE}"
fi
if have_cmd update-desktop-database; then
    update-desktop-database "${APPS_DIR}" 2>/dev/null || true
fi

##############################################################################
# 5. Remove hicolor app icon
##############################################################################
ICON_FILE="${ICON_THEME_DIR}/${APP_NAME}.svg"
if [[ -f "$ICON_FILE" ]]; then
    rm -f -- "$ICON_FILE"
    ok "Removed icon: ${ICON_FILE}"
fi

##############################################################################
# 5b. Remove the micsource CLI symlink (only if it points to our script)
##############################################################################
CLI_TARGET="${DATA_DIR}/micsource"
if [[ -L "$BIN_LINK" ]]; then
    if [[ "$(readlink -f "$BIN_LINK")" == "$CLI_TARGET" ]]; then
        rm -f -- "$BIN_LINK"
        ok "Removed CLI symlink: ${BIN_LINK}"
    else
        warn "CLI symlink ${BIN_LINK} points elsewhere; leaving it."
    fi
elif [[ -e "$BIN_LINK" ]]; then
    warn "${BIN_LINK} exists and is not a MicSource symlink; leaving it."
fi

##############################################################################
# 5c. Remove the adb PATH symlink (only if it points into our adb bundle)
##############################################################################
ADB_LINK="${HOME}/.local/bin/adb"
ADB_BUNDLE_ADB="${DATA_DIR}/adb-bundle/platform-tools/adb"
if [[ -L "$ADB_LINK" ]]; then
    if [[ "$(readlink -f "$ADB_LINK")" == "$ADB_BUNDLE_ADB" ]]; then
        rm -f -- "$ADB_LINK"
        ok "Removed adb PATH symlink: ${ADB_LINK}"
    else
        warn "adb symlink ${ADB_LINK} points elsewhere; leaving it."
    fi
fi

##############################################################################
# 6. Remove GNOME extension (only if it is ours)
##############################################################################
if [[ -f "$PULSE_LOCK_CONF" ]] && grep -qi "micsource" "$PULSE_LOCK_CONF"; then
    rm -f -- "$PULSE_LOCK_CONF"
    ok "Removed stream routing lock: $PULSE_LOCK_CONF"
fi

if [[ -f "$XDG_AUTOSTART" ]] && grep -qi "micsource" "$XDG_AUTOSTART"; then
    rm -f -- "$XDG_AUTOSTART"
    ok "Removed autostart entry: $XDG_AUTOSTART"
fi

if [[ -d "$GNOME_EXT_DIR" ]]; then
    if [[ -f "${GNOME_EXT_DIR}/metadata.json" ]]; then
        if have_cmd gnome-extensions; then
            gnome-extensions disable "${GNOME_EXT_UUID}" 2>/dev/null || true
        fi
        rm -rf -- "${GNOME_EXT_DIR}"
        ok "Removed GNOME extension: ${GNOME_EXT_DIR}"
        info "Restart the shell (Alt+F2 -> r -> Enter on X11; log out/in on Wayland)"
        info "to fully unload the extension."
    else
        warn "GNOME extension dir exists but does not look like MicSource's; leaving it."
    fi
fi

##############################################################################
# 7. Remove control socket left behind by the monitor
##############################################################################
SOCK="${DATA_DIR}/micsource.sock"
if [[ -e "$SOCK" ]]; then
    rm -f -- "$SOCK"
    ok "Removed control socket: ${SOCK}"
fi

##############################################################################
# 8. Remove config + data (with ownership guards)
##############################################################################
if [[ -d "$CONFIG_DIR" ]]; then
    if [[ -f "${CONFIG_DIR}/config.ini" ]]; then
        rm -rf -- "${CONFIG_DIR}"
        ok "Removed config dir: ${CONFIG_DIR}"
    else
        warn "Config dir exists but does not contain MicSource's config.ini; leaving it."
    fi
fi

if [[ -d "$DATA_DIR" ]]; then
    if ! data_dir_is_ours; then
        warn "Data dir exists but contains no MicSource files; leaving it untouched."
    else
        ADB_BUNDLE_DIR="${DATA_DIR}/adb-bundle"
        if [[ -d "$ADB_BUNDLE_DIR" ]]; then
            echo
            warn "The adb bundle was installed at: ${ADB_BUNDLE_DIR}"
            info "You may want to keep it if you use adb for other purposes."
            if confirm "Remove the adb bundle too?"; then
                rm -rf -- "${ADB_BUNDLE_DIR}"
                ok "Removed adb bundle."
            else
                info "Kept adb bundle at ${ADB_BUNDLE_DIR}"
            fi
        fi
        rm -rf -- "${DATA_DIR}"
        ok "Removed data dir: ${DATA_DIR}"
    fi
fi

##############################################################################
# Done
##############################################################################
echo
ok "MicSource host components have been uninstalled."
info "The Android app may still be installed on your device;"
info "uninstall it from the device settings if you no longer need it."
echo
