#!/usr/bin/env bash
#
# install.sh - MicSource Linux host installer
#
# Installs the host side of MicSource (a fork of the AudioSource Android
# app) into your user account (no root). The payload programs are real
# files under linux-install/assets/ (the source of truth); this script
# copies them into place instead of embedding heredocs:
#   * payload assets -> ~/.local/share/micsource/ (CLI, GUI wrapper,
#     app/tray/monitor Python)
#   * adb (bundled if missing)
#   * optional adb forward + Android-app start on the connected device
#   * control window, tray script, CLI, systemd user service
#   * app-drawer launcher + icons + config (existing config is preserved)
#   * optional GNOME quick settings pill (extension, GNOME Shell 47+)
#   * PipeWire stream-routing lock for the virtual microphone
#
# Android identifiers intentionally keep the upstream names (baked into the
# APK): package fr.dzx.audiosource, device socket "audiosource". The host
# forward maps localabstract:micsource -> localabstract:audiosource.
set -euo pipefail

# Shared helpers, colors, and install paths live in common.sh.
# (Sourcing a relative library file; shellcheck does not follow it → /dev/null.)
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "${SRC_DIR}/common.sh"

##############################################################################
# Script-specific paths (BIN_LINK, ADB_LINK, AUTOSTART_FILE, GNOME_EXT_*,
# PULSE_LOCK_CONF and the rest of the shared layout come from common.sh)
##############################################################################
CONFIG_PATH="${CONFIG_DIR}/config.ini"
DATA_ICON="${DATA_DIR}/micsource-icon.svg"
ICON_PATH="${ICON_THEME_DIR}/${APP_NAME}.svg"
DESKTOP_FILE="${APPS_DIR}/${APP_NAME}.desktop"
UNIT_FILE="${SYSTEMD_USER_DIR}/${APP_NAME}.service"
CLI_PATH="${DATA_DIR}/${APP_NAME}"
ADB_PATH_FILE="${DATA_DIR}/adb.path"
ADB_BUNDLE_DIR="${DATA_DIR}/adb-bundle"
PLATFORM_TOOLS_VERSION="37.0.1"
PLATFORM_TOOLS_SHA256="d230f13842f60f782a8645f9c813f8f845bf36089ea7289f28c48f17979313f1"
PLATFORM_TOOLS_SHA1="477254aa5f903c15cf51001717bdf347fb6b53e0"

ANDROID_PKG="fr.dzx.audiosource" # Android package (baked into the APK)
DEVICE_SOCKET="audiosource"      # device-side socket (RecordThread)
HOST_SOCKET="${APP_NAME}"        # host side of the adb forward

##############################################################################
# Download + summary plumbing
##############################################################################

# fetch <url> <dest>: download with curl (preferred) or wget; non-zero on
# failure. Every download in this script goes through here.
fetch() {
    local url="$1" dest="$2"
    if have_cmd curl; then
        curl -fL --retry 2 --connect-timeout 15 -o "${dest}" "${url}"
    elif have_cmd wget; then
        wget -q --tries=2 -O "${dest}" "${url}"
    else
        err "Need curl or wget to download: ${url}"
        return 1
    fi
}

# Download scratch dirs under DATA_DIR, removed by the EXIT trap below (and
# safe to re-remove after a step cleaned its own dir explicitly).
TMP_DIRS=()

# (Registered via trap EXIT below; shellcheck cannot see that call → false
# positive SC2317.)
# shellcheck disable=SC2317
cleanup_tmp() {
    local d
    for d in ${TMP_DIRS[@]+"${TMP_DIRS[@]}"}; do
        rm -rf -- "${d}"
    done
}
trap cleanup_tmp EXIT

# Step results: every step records ok | skipped | failed; the summary prints
# one line per step and the installer exits 1 iff a REQUIRED step failed.
STEP_RESULTS=()
REQUIRED_STEPS=(assets config desktop cli systemd)

record_step() { # record_step <name> <ok|skipped|failed>
    STEP_RESULTS+=("${1}:${2}")
}

# run_step <name> <step-fn...>: run one install step and record its result.
# Step convention: 0 = ok, 2 = skipped (not applicable, or declined by the
# user), any other status = failed.
run_step() {
    local name="$1" rc=0
    shift
    "$@" || rc=$?
    case "${rc}" in
    0) record_step "${name}" ok ;;
    2) record_step "${name}" skipped ;;
    *) record_step "${name}" failed ;;
    esac
    return 0
}

# write_or_fail <path>: copy stdin into <path>, failing the calling step when
# the write fails. Required-step writes need this explicit check: run_step
# runs a step as `"$@" || rc=$?`, and inside that `||` context `set -e` is
# suspended, so an unchecked failed write (read-only dir, ENOSPC) would fall
# through to the step's trailing ok and be recorded as success.
write_or_fail() {
    local path="$1"
    if ! cat >"${path}"; then
        err "Failed to write ${path}"
        return 1
    fi
}

print_summary() {
    local entry name status
    echo
    echo "== Summary =="
    for entry in ${STEP_RESULTS[@]+"${STEP_RESULTS[@]}"}; do
        name="${entry%%:*}"
        status="${entry##*:}"
        case "${status}" in
        ok) ok "${name}" ;;
        skipped) warn "${name} (skipped)" ;;
        *) err "${name} (FAILED)" ;;
        esac
    done
    echo
}

required_failed() { # true iff any required step recorded failed
    local entry name status
    for entry in ${STEP_RESULTS[@]+"${STEP_RESULTS[@]}"}; do
        name="${entry%%:*}"
        status="${entry##*:}"
        [[ "${status}" == "failed" ]] || continue
        case " ${REQUIRED_STEPS[*]} " in
        *" ${name} "*) return 0 ;;
        esac
    done
    return 1
}

# gnome_desktop: true iff the session looks like GNOME (XDG_CURRENT_DESKTOP
# is colon-separated and can hold e.g. "ubuntu:GNOME").
gnome_desktop() {
    case "${XDG_CURRENT_DESKTOP:-}:${GNOME_DESKTOP_SESSION_ID:-}" in
    *[Gg][Nn][Oo][Mm][Ee]*) return 0 ;;
    *) return 1 ;;
    esac
}

WITH_TRAY=0
NO_DEVICE=0
for arg in "$@"; do
    case "${arg}" in
    --with-tray) WITH_TRAY=1 ;;
    --no-device) NO_DEVICE=1 ;;
    -h | --help)
        cat <<USAGE
Usage: install.sh [--with-tray] [--no-device]

  --with-tray  enable the legacy tray icon at login (XDG autostart).
               Without the flag the tray stays opt-in; enable it from the
               control window's Preferences at any time.
  --no-device  skip adb setup and all device probing/install/forwarding.
               Useful for preparing host files without an attached phone.
USAGE
        exit 0
        ;;
    *)
        err "Unknown option: ${arg}"
        printf 'Usage: install.sh [--with-tray] [--no-device]\n' >&2
        exit 2
        ;;
    esac
done

step_sanity() {
    # refuse_root() prints the root error and exits; it carries no EUID
    # check of its own, so the guard lives at the call site.
    if [[ "$EUID" -eq 0 ]]; then
        refuse_root
    fi
    if [[ "$(uname -s)" != "Linux" ]]; then
        err "This installer supports Linux only."
        exit 1
    fi
    if [[ -z "${HOME:-}" ]]; then
        err "HOME is not set; cannot determine install paths."
        exit 1
    fi
    if [[ ! -d "${HOME}" || ! -w "${HOME}" ]]; then
        err "HOME (${HOME}) is not a writable directory; cannot install."
        exit 1
    fi
    if ! command -v python3 >/dev/null 2>&1; then
        err "python3 is required (the control window, tray and monitor are Python); install it and re-run."
        exit 1
    fi
    if ! mkdir -p "${DATA_DIR}" "${CONFIG_DIR}" "${APPS_DIR}" \
        "${SYSTEMD_USER_DIR}" "${ICON_THEME_DIR}" \
        "$(dirname "${GNOME_EXT_DIR}")" "${HOME}/.local/bin"; then
        err "Cannot create the MicSource install directories under ${HOME}."
        exit 1
    fi
}

step_assets() {
    local f failed=0
    for f in micsource micsource-gui paths.py micsource-app.py micsource-tray.py \
        micsource-monitor.py micsource_adb.py; do
        if [[ ! -f "${INSTALL_DIR}/assets/${f}" ]]; then
            err "Missing installer asset: ${INSTALL_DIR}/assets/${f}"
            failed=1
            continue
        fi
        if ! cp -f "${INSTALL_DIR}/assets/${f}" "${DATA_DIR}/${f}"; then
            err "Failed to install payload file: ${DATA_DIR}/${f}"
            failed=1
        fi
    done
    if [[ "${failed}" -ne 0 ]]; then
        return 1
    fi
    chmod 755 "${DATA_DIR}/micsource" "${DATA_DIR}/micsource-gui" \
        "${DATA_DIR}/micsource-app.py" \
        "${DATA_DIR}/micsource-tray.py" "${DATA_DIR}/micsource-monitor.py" \
        "${DATA_DIR}/micsource_adb.py" || {
        err "Failed to make the payload files executable in ${DATA_DIR}"
        return 1
    }
    ok "Payload files installed: ${DATA_DIR}"
}

step_adb() {
    if [[ "${NO_DEVICE}" -eq 1 ]]; then
        info "--no-device: skipping adb setup."
        return 2
    fi
    local adb_bin="" adb_port

    # Migrate only a MicSource-owned link from older installs. This runs
    # before command -v so that a later system adb can be discovered.
    if [[ -L "${ADB_LINK}" ]] &&
        [[ "$(readlink -f "${ADB_LINK}")" == "$(readlink -f "${ADB_BUNDLE_DIR}/platform-tools/adb")" ]]; then
        if ! rm -f -- "${ADB_LINK}"; then
            err "Could not remove legacy MicSource adb link: ${ADB_LINK}"
            return 1
        fi
        ok "Removed legacy MicSource adb link: ${ADB_LINK}"
    fi

    if have_cmd adb; then
        adb_bin="$(command -v adb)"
        ok "adb found on PATH: ${adb_bin}"
    elif [[ -x "${ADB_BUNDLE_DIR}/platform-tools/adb" ]]; then
        adb_bin="${ADB_BUNDLE_DIR}/platform-tools/adb"
        ok "adb found in the MicSource bundle: ${adb_bin}"
    else
        warn "adb not found (needed to talk to the phone)."
        if ! confirm "Install the official Google platform-tools bundle?"; then
            info "Skipping adb bundle install; install adb yourself and re-run."
            return 2
        fi
        if ! have_cmd unzip; then
            err "'unzip' is required to unpack the bundle; install it and re-run."
            return 1
        fi
        if ! have_cmd sha256sum || ! have_cmd sha1sum; then
            err "'sha256sum' and 'sha1sum' are required to verify platform-tools."
            return 1
        fi
        local url scratch zip
        url="https://dl.google.com/android/repository/platform-tools_r${PLATFORM_TOOLS_VERSION}-linux.zip"
        scratch="$(mktemp -d "${DATA_DIR}/.dl.XXXXXX")" || {
            err "Could not create a download directory under ${DATA_DIR}."
            return 1
        }
        TMP_DIRS+=("${scratch}")
        zip="${scratch}/platform-tools.zip"
        info "Downloading platform-tools..."
        if ! fetch "${url}" "${zip}"; then
            err "Download failed."
            return 1
        fi
        if ! printf '%s  %s\n' "${PLATFORM_TOOLS_SHA256}" "${zip}" |
            sha256sum --check --status; then
            err "SHA-256 verification failed for platform-tools ${PLATFORM_TOOLS_VERSION}."
            return 1
        fi
        if ! printf '%s  %s\n' "${PLATFORM_TOOLS_SHA1}" "${zip}" |
            sha1sum --check --status; then
            err "Google SDK metadata SHA-1 verification failed for platform-tools ${PLATFORM_TOOLS_VERSION}."
            return 1
        fi
        unzip -q "${zip}" -d "${scratch}" || {
            err "Unpack failed."
            return 1
        }
        mkdir -p "${ADB_BUNDLE_DIR}"
        if [[ -d "${ADB_BUNDLE_DIR}/platform-tools" ]]; then
            warn "Existing platform-tools found; replacing."
            rm -rf "${ADB_BUNDLE_DIR}/platform-tools"
        fi
        mv -T "${scratch}/platform-tools" "${ADB_BUNDLE_DIR}/platform-tools"
        rm -rf "${scratch}" # success: drop the scratch now (the trap is the backstop)
        adb_bin="${ADB_BUNDLE_DIR}/platform-tools/adb"
        ok "adb bundle installed: ${adb_bin}"
    fi

    adb_port="$(read_adb_server_port)" || return 1
    printf '%s\n' "${adb_bin}" >"${ADB_PATH_FILE}"
    info "MicSource ADB server port: ${adb_port}"
}

read_adb_server_port() {
    local port="5038"
    if [[ -f "${CONFIG_PATH}" ]]; then
        port="$(awk -F= '/^[[:space:]]*server_port[[:space:]]*=/ {gsub(/[[:space:]]/, "", $2); print $2; exit}' "${CONFIG_PATH}")"
        port="${port:-5038}"
    fi
    if [[ ! "${port}" =~ ^[0-9]+$ ]]; then
        err "Invalid [adb] server_port '${port}'; 5037 is reserved for system ADB, choose another port from 1024-65535."
        return 1
    fi
    port=$((10#${port}))
    if ((port < 1024 || port > 65535 || port == 5037)); then
        err "Invalid [adb] server_port '${port}'; 5037 is reserved for system ADB, choose another port from 1024-65535."
        return 1
    fi
    printf '%s\n' "${port}"
}

read_device_serial() {
    # USB and Wireless debugging can both be online for the same phone;
    # without -s every adb command fails with "more than one device/emulator".
    local serial=""
    if [[ -f "${CONFIG_PATH}" ]]; then
        serial="$(awk -F= '/^[[:space:]]*serial[[:space:]]*=/ {sub(/^[^=]*=[[:space:]]*/, ""); gsub(/[[:space:]]/, ""); print; exit}' "${CONFIG_PATH}")"
    fi
    printf '%s\n' "${serial}"
}

step_device() {
    if [[ "${NO_DEVICE}" -eq 1 ]]; then
        info "--no-device: skipping device install and forwarding."
        return 2
    fi
    local adb_bin
    adb_bin="$(cat "${ADB_PATH_FILE}" 2>/dev/null || echo "")"
    if [[ -z "${adb_bin}" || ! -x "${adb_bin}" ]]; then
        warn "adb unavailable; skipping device setup."
        return 2
    fi

    local state adb_port serial
    serial="$(read_device_serial)"
    adb_port="$(read_adb_server_port)" || return 1
    local adb_target=()
    if [[ -n "${serial}" ]]; then
        adb_target=(-s "${serial}")
    fi
    state="$("${adb_bin}" -P "${adb_port}" "${adb_target[@]}" get-state 2>&1 || true)"
    if [[ "${state,,}" == *"cannot bind"* ||
        "${state,,}" == *"address already in use"* ||
        "${state,,}" == *"failed to start daemon"* ]]; then
        err "MicSource ADB server port ${adb_port} is unavailable: ${state}"
        return 1
    fi
    if [[ "${state}" != "device" ]]; then
        if [[ "${state,,}" == *"more than one"* ]]; then
            warn "More than one Android device/transport is online."
            info "Select the target once with:"
            info "  micsource devices          # list serials"
            info "  micsource device-select SERIAL"
            return 2
        fi
        warn "No Android device online (state: ${state:-none})."
        if [[ -n "${serial}" ]]; then
            info "The configured device (${serial}) is offline. Pick another with"
            info "  micsource devices && micsource device-select SERIAL"
        fi
        info "USB: connect the phone, enable USB debugging, authorize this host."
        info "Wi-Fi (Android 11+): phone and PC on the same network, then use"
        info "Wireless debugging (Developer options) from the control window or:"
        info "  micsource wireless-pair IP:PORT      # code shown by the phone"
        info "  micsource wireless-connect IP:PORT    # separate connect endpoint"
        info "Install the MicSource APK on the phone from:"
        info "  https://github.com/mhasanmuammar/micsource/releases/latest"
        return 2
    fi
    # The APK is distributed through GitHub Releases and installed on the
    # phone itself; the host only starts it (if present) and forwards the
    # device socket.
    "${adb_bin}" -P "${adb_port}" "${adb_target[@]}" shell am start \
        -n "${ANDROID_PKG}/.MainActivity" --ez start true >/dev/null 2>&1 || true
    if "${adb_bin}" -P "${adb_port}" "${adb_target[@]}" forward "localabstract:${HOST_SOCKET}" \
        "localabstract:${DEVICE_SOCKET}" >/dev/null 2>&1; then
        ok "adb forward set: localabstract:${HOST_SOCKET} -> localabstract:${DEVICE_SOCKET}"
        return 0
    fi
    warn "adb forward failed; the host cannot reach the phone mic yet."
    info "Run 'micsource start' after installing the APK from GitHub Releases."
    return 1
}

step_config() {
    if [[ -f "${CONFIG_PATH}" ]]; then
        ok "Existing config preserved: ${CONFIG_PATH}"
        return 0
    fi
    if [[ -e "${CONFIG_PATH}" ]]; then
        err "Cannot write config: ${CONFIG_PATH} exists and is not a regular file."
        return 1
    fi
    write_or_fail "${CONFIG_PATH}" <<'CONF' || return 1
# MicSource host configuration
# Managed by linux-install/install.sh; edit by hand or re-run installer.

[general]
app_name = micsource
android_package = fr.dzx.audiosource

[adb]
# Path to adb binary (auto-detected). Leave empty to use PATH adb.
adb_path =
# Isolated local ADB server port (system ADB defaults to 5037).
server_port = 5038

[device]
# Serial of the target device (empty = first device).
serial =

[socket]
# Host-side forwarded socket name (tray/monitor connect here).
host_socket_name = micsource
# Device-side socket name baked into the Android app (do not change here).
device_socket_name = audiosource

[audio]
# Playback backend: auto, paplay, or aplay.
backend = auto
# Play phone audio through the PC speakers (paplay/aplay).
play_to_speakers = false
# Expose the phone mic as a system input source named "phone-mic".
virtual_mic = true
CONF
    chmod 600 "${CONFIG_PATH}" || {
        err "Failed to set mode 600 on ${CONFIG_PATH}"
        return 1
    }
    ok "Config written: ${CONFIG_PATH}"
}

step_desktop() {
    local icon_name="micsource"

    if [[ -f "${PROJECT_ROOT}/assets/icon.svg" ]]; then
        if ! cp -f "${PROJECT_ROOT}/assets/icon.svg" "${DATA_ICON}" ||
            ! cp -f "${PROJECT_ROOT}/assets/icon.svg" "${ICON_PATH}"; then
            err "Failed to install the app icon into ${ICON_THEME_DIR}"
            return 1
        fi
        ok "App icon installed: ${ICON_PATH}"
    else
        icon_name="audio-input-microphone"
        warn "No SVG icon found; the launcher falls back to the themed mic icon."
    fi

    write_or_fail "${DESKTOP_FILE}" <<DESKEOF || return 1
[Desktop Entry]
Type=Application
Name=MicSource
GenericName=Phone Microphone over USB
Comment=Use your Android phone as a PC microphone (adb forwarded PCM stream)
Exec=${DATA_DIR}/micsource-gui
Icon=${icon_name}
Categories=Audio;AudioVideo;Utility;
Keywords=microphone;mic;phone;audio;
Terminal=false
DESKEOF
    if have_cmd update-desktop-database; then
        update-desktop-database "${APPS_DIR}" >/dev/null 2>&1 || true
    fi
    ok "App drawer launcher installed: ${DESKTOP_FILE}"
}

step_cli() {
    if [[ -L "${BIN_LINK}" ]]; then
        if [[ "$(readlink -f "${BIN_LINK}")" == "$(readlink -f "${CLI_PATH}")" ]]; then
            ok "CLI symlink already in place: ${BIN_LINK}"
        else
            warn "${BIN_LINK} is a symlink pointing elsewhere; leaving it."
        fi
    elif [[ -e "${BIN_LINK}" ]]; then
        warn "${BIN_LINK} exists and is not a MicSource symlink; leaving it."
    else
        if ! ln -s "${CLI_PATH}" "${BIN_LINK}"; then
            err "Failed to create the CLI symlink: ${BIN_LINK}"
            return 1
        fi
        ok "CLI symlink: ${BIN_LINK} -> ${CLI_PATH}"
    fi

    case ":${PATH}:" in
    *:"${HOME}/.local/bin":*) : ;;
    *)
        warn "${HOME}/.local/bin is not on your PATH."
        info "Add it permanently:  export PATH=\"${HOME}/.local/bin:\$PATH\""
        ;;
    esac
    ok "CLI ready.  Try: micsource help"
}

step_tray() {
    if [[ "${WITH_TRAY}" -eq 1 ]]; then
        local autostart_dir
        autostart_dir="$(dirname "${AUTOSTART_FILE}")"
        if ! mkdir -p "${autostart_dir}"; then
            err "Failed to create ${autostart_dir}"
            return 1
        fi
        write_or_fail "${AUTOSTART_FILE}" <<AUTOEOF || return 1
[Desktop Entry]
Type=Application
Name=MicSource Tray
Comment=MicSource tray icon (phone microphone over USB)
Exec=${DATA_DIR}/micsource-tray.py
Icon=micsource
Terminal=false
X-GNOME-Autostart-enabled=true
AUTOEOF
        ok "Tray autostart installed: ${AUTOSTART_FILE}"
    else
        info "Tray is opt-in: enable it from the control window's Preferences."
    fi
    # Gio/GLib are the tray's only bindings; Gtk/AppIndicator are not needed.
    if ! python3 -c 'from gi.repository import Gio, GLib' >/dev/null 2>&1; then
        warn "PyGObject GLib/Gio bindings are not available; the tray cannot start."
        info "Install Python 3 PyGObject (often packaged as python3-gi)."
        info "A StatusNotifier watcher must also be running in the desktop session."
    fi
}

step_systemd() {
    write_or_fail "${UNIT_FILE}" <<UNITEOF || return 1
[Unit]
Description=MicSource host monitor (adb socket forward + audio playback)
After=graphical-session.target
Wants=graphical-session.target

[Service]
Type=simple
ExecStart="${DATA_DIR}/micsource-monitor.py"
Restart=on-failure
RestartSec=5
WorkingDirectory=${DATA_DIR}
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=graphical-session.target
UNITEOF
    if have_cmd systemctl; then
        systemctl --user daemon-reload >/dev/null 2>&1 || true
        ok "systemd user unit installed: ${UNIT_FILE}"
        info "Enable and start it after install with:"
        info "  systemctl --user enable --now micsource"
    else
        warn "systemctl not found; the monitor must be started manually:"
        info "  ${CLI_PATH} run   # foreground monitor (Ctrl+C to stop)"
    fi
}

step_gnome_extension() {
    if ! gnome_desktop; then
        info "Not a GNOME desktop; skipping the quick settings pill."
        info "Manual install path: copy the files from"
        info "  ${INSTALL_DIR}/assets/gnome/  into  ${GNOME_EXT_DIR}"
        info "then enable ${GNOME_EXT_UUID} (Extensions app, or:"
        info "  gnome-extensions enable ${GNOME_EXT_UUID})."
        return 2
    fi
    mkdir -p "${GNOME_EXT_DIR}"
    cp -f "${INSTALL_DIR}/assets/gnome/extension.js" "${GNOME_EXT_DIR}/extension.js"
    cp -f "${INSTALL_DIR}/assets/gnome/prefs.js" "${GNOME_EXT_DIR}/prefs.js"
    cp -f "${INSTALL_DIR}/assets/gnome/metadata.json" "${GNOME_EXT_DIR}/metadata.json"
    ok "GNOME quick settings pill installed: ${GNOME_EXT_DIR}"
    if have_cmd gnome-extensions; then
        info "Enable it with:"
        info "  gnome-extensions enable ${GNOME_EXT_UUID}"
        info "(or from the control window's Preferences, or the Extensions app;"
        info "if it does not appear right away, log out and back in)"
    else
        info "gnome-extensions not found; the pill can be enabled from the"
        info "Extensions app once GNOME Shell provides it."
    fi
}

step_pipewire() {
    mkdir -p "$(dirname "${PULSE_LOCK_CONF}")"
    cat >"${PULSE_LOCK_CONF}" <<LOCKEOF
# MicSource host install: never re-route streams aimed at the MicSource
# virtual sink. PipeWire was observed moving such streams onto the desktop
# default output (stream-restore / WirePlumber policy), leaving the
# virtual mic silent and playing the phone audio out of the speakers.
stream.rules = [
  {
    matches = [ { target.object = "phone-out" } ]
    actions = { update-props = {
      node.dont-move = true
      node.dont-fallback = true
    } }
  }
]
LOCKEOF
    ok "Stream routing lock installed: ${PULSE_LOCK_CONF}"
    if have_cmd systemctl; then
        systemctl --user try-restart pipewire-pulse >/dev/null 2>&1 || true
    fi
}

main() {
    echo "${BLD}=== MicSource Linux Host Installer ===${RST}"
    echo
    step_sanity # bare: a failed sanity check exits immediately (nothing installed yet)
    run_step assets step_assets
    run_step adb step_adb
    run_step device step_device
    run_step config step_config
    run_step desktop step_desktop
    run_step cli step_cli
    run_step tray step_tray
    run_step systemd step_systemd
    run_step gnome_ext step_gnome_extension
    run_step pipewire step_pipewire
    print_summary
    if required_failed; then
        err "Required install steps failed; fix the problems above and re-run."
        exit 1
    fi
    echo
    ok "MicSource host-side install complete."
    info "Quick start:"
    info "  systemctl --user enable --now micsource   # background service"
    info "  micsource window                          # control window"
    info "Launch 'MicSource' from the app drawer for a one-click GUI."
    info "Then point any app (browser/VOIP/recorder) at the 'phone-mic' input."
    echo
}

main "$@"
