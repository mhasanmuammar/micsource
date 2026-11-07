#!/usr/bin/env bash
#
# common.sh - Shared helpers and install paths for the MicSource scripts
#
# Sourced by install.sh and uninstall.sh; never executed directly. It sets no
# shell options and performs no actions beyond defining helpers and variables.
# Consumers enable their own `set -euo pipefail` before sourcing.
#
# Exposes:
#   * logging helpers : info() ok() warn() err() ask() confirm()
#   * tool helpers    : have_cmd() refuse_root()
#   * colors          : RED GRN YLW BLU BLD RST (empty for non-TTY / NO_COLOR)
#   * install paths   : APP_NAME INSTALL_DIR PROJECT_ROOT CONFIG_DIR DATA_DIR
#                       APPS_DIR SYSTEMD_USER_DIR ICON_THEME_DIR
#                       GNOME_EXT_UUID GNOME_EXT_DIR PULSE_LOCK_CONF
#                       AUTOSTART_FILE BIN_LINK ADB_LINK

# Direct-execution guard: this file is a library, not a runnable script.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    printf '%s\n' "error: common.sh must be sourced by install.sh/uninstall.sh, not executed" >&2
    exit 1
fi

APP_NAME="micsource"

INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC2034  # PROJECT_ROOT is used by install.sh only
PROJECT_ROOT="$(dirname "${INSTALL_DIR}")"

# ANSI colors only when stdout is a terminal and NO_COLOR is unset.
# (The color and path variables are consumed by the scripts that source us.)
# shellcheck disable=SC2034
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    RED=$'\e[31m'
    GRN=$'\e[32m'
    YLW=$'\e[33m'
    BLU=$'\e[34m'
    BLD=$'\e[1m'
    RST=$'\e[0m'
else
    RED=""
    GRN=""
    YLW=""
    BLU=""
    BLD=""
    RST=""
fi

info() { printf '%s[INFO]%s  %s\n' "${BLU}" "${RST}" "$*"; }
ok() { printf '%s[OK]%s   %s\n' "${GRN}" "${RST}" "$*"; }
warn() { printf '%s[WARN]%s %s\n' "${YLW}" "${RST}" "$*"; }
err() { printf '%s[ERR]%s  %s\n' "${RED}" "${RST}" "$*" >&2; }
ask() { printf '%s[?]%s  %s ' "${YLW}" "${RST}" "$*"; }

confirm() {
    local prompt="${1:-Proceed?}"
    local ans
    ask "${prompt} [y/N] "
    read -r ans || true
    case "${ans}" in
    y | Y | yes | Yes | YES) return 0 ;;
    *) return 1 ;;
    esac
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }

refuse_root() {
    err "Do not run this installer as root. Run it as your normal user."
    exit 1
}

##############################################################################
# shellcheck disable=SC2034  # installed-layout vars are consumed by the
# scripts that source this file; PROJECT_ROOT is used by install.sh only.
CONFIG_DIR="${HOME}/.config/${APP_NAME}"
# shellcheck disable=SC2034
DATA_DIR="${HOME}/.local/share/${APP_NAME}"
# shellcheck disable=SC2034
APPS_DIR="${HOME}/.local/share/applications"
# shellcheck disable=SC2034
SYSTEMD_USER_DIR="${HOME}/.config/systemd/user"
# shellcheck disable=SC2034
ICON_THEME_DIR="${HOME}/.local/share/icons/hicolor/scalable/apps"
GNOME_EXT_UUID="micsource-tile@micsource.local"
# shellcheck disable=SC2034
GNOME_EXT_DIR="${HOME}/.local/share/gnome-shell/extensions/${GNOME_EXT_UUID}"
# shellcheck disable=SC2034
PULSE_LOCK_CONF="${HOME}/.config/pipewire/pipewire-pulse.conf.d/10-micsource-stream-lock.conf"
# shellcheck disable=SC2034
AUTOSTART_FILE="${HOME}/.config/autostart/micsource-tray.desktop"
# shellcheck disable=SC2034
BIN_LINK="${HOME}/.local/bin/${APP_NAME}"
# shellcheck disable=SC2034
ADB_LINK="${HOME}/.local/bin/adb"
