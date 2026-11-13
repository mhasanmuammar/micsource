#!/usr/bin/env bash
#
# install.sh - MicSource Linux host installer
#
# Installs the host side of MicSource (a fork of the AudioSource Android
# app) into your user account (no root). The payload programs are real
# files under linux-install/assets/ (the source of truth); this script
# copies them into place instead of embedding heredocs:
#   * payload assets -> ~/.local/share/micsource/ (CLI, GUI wrapper, build
#     helper, app/tray/monitor Python) + project.path pointing back at the
#     checkout
#   * adb (bundled if missing) + optional portable JDK 17 / Android SDK
#   * builds or stages the APK and installs it on the connected device
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
APK_PATH_FILE="${DATA_DIR}/apk.path"
ENV_PATH_FILE="${DATA_DIR}/build-env.path"
BUILD_ENV_DIR="${DATA_DIR}/build-env"
ADB_BUNDLE_DIR="${DATA_DIR}/adb-bundle"
STAGED_APK="${DATA_DIR}/micsource-release.apk"

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
for arg in "$@"; do
    case "${arg}" in
    --with-tray) WITH_TRAY=1 ;;
    -h | --help)
        cat <<USAGE
Usage: install.sh [--with-tray]

  --with-tray  enable the legacy tray icon at login (XDG autostart).
               Without the flag the tray stays opt-in; enable it from the
               control window's Preferences at any time.
USAGE
        exit 0
        ;;
    *)
        err "Unknown option: ${arg}"
        printf 'Usage: install.sh [--with-tray]\n' >&2
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
    for f in micsource micsource-gui micsource-build \
        micsource-app.py micsource-tray.py micsource-monitor.py; do
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
        "${DATA_DIR}/micsource-build" "${DATA_DIR}/micsource-app.py" \
        "${DATA_DIR}/micsource-tray.py" "${DATA_DIR}/micsource-monitor.py" || {
        err "Failed to make the payload files executable in ${DATA_DIR}"
        return 1
    }
    if ! printf '%s\n' "${PROJECT_ROOT}" >"${DATA_DIR}/project.path"; then
        err "Failed to write ${DATA_DIR}/project.path"
        return 1
    fi
    ok "Payload files installed: ${DATA_DIR}"
}

step_adb() {
    local adb_bin=""

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
        local url scratch zip
        url="https://dl.google.com/android/repository/platform-tools-latest-linux.zip"
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
        if [[ -L "${ADB_LINK}" ]]; then
            if [[ "$(readlink -f "${ADB_LINK}")" == "$(readlink -f "${adb_bin}")" ]]; then
                ok "adb symlink already in place."
            else
                warn "${ADB_LINK} exists pointing elsewhere; leaving it (use ${adb_bin})."
            fi
        elif [[ -e "${ADB_LINK}" ]]; then
            warn "${ADB_LINK} exists and is not a symlink; leaving it."
        else
            ln -s "${adb_bin}" "${ADB_LINK}"
            ok "Linked ${ADB_LINK} -> ${adb_bin}"
        fi
    fi

    printf '%s\n' "${adb_bin}" >"${ADB_PATH_FILE}"

    case ":${PATH}:" in
    *:"${HOME}/.local/bin":*) : ;;
    *)
        warn "${HOME}/.local/bin is not on your PATH."
        info "Add it permanently:  export PATH=\"${HOME}/.local/bin:\$PATH\""
        ;;
    esac
}

env_set_if_portable() {
    # Source the installer-managed JDK/SDK so gradle sees them.
    if [[ -f "${ENV_PATH_FILE}" ]]; then
        # shellcheck disable=SC1090
        source "${ENV_PATH_FILE}"
        export JAVA_HOME ANDROID_HOME
    fi
}

step_build_env() {
    local jdk17_ok=0
    if have_cmd java; then
        local major
        major="$(java -version 2>&1 | head -1 | grep -oP '"\K[0-9]+' | head -1)"
        if [[ -n "${major}" && "${major}" -ge 17 ]]; then
            jdk17_ok=1
        fi
    fi
    local sdk_ok=0
    if [[ -z "${ANDROID_HOME:-}" && -f "${PROJECT_ROOT}/local.properties" ]]; then
        ANDROID_HOME="$(grep -oP '^sdk\.dir=\K.*' "${PROJECT_ROOT}/local.properties" 2>/dev/null | head -1 || true)"
    fi
    if [[ -n "${ANDROID_HOME:-}" && -d "${ANDROID_HOME}" ]]; then sdk_ok=1; fi

    if grep -q JAVA_HOME "${ENV_PATH_FILE}" 2>/dev/null; then
        ok "Portable build environment already installed (${BUILD_ENV_DIR})."
        return 0
    fi

    if [[ "${jdk17_ok}" -eq 1 && "${sdk_ok}" -eq 1 ]]; then
        ok "System JDK 17 + Android SDK already available."
        return 0
    fi

    warn "No complete JDK 17 + Android SDK build environment found."
    warn "(Only needed to BUILD the APK from source; a prebuilt APK can be staged instead.)"
    if ! confirm "Download and install a portable Temurin JDK 17 + Android cmdline-tools?"; then
        info "Skipping build environment; re-run install.sh later to build from source."
        return 2
    fi
    local arch
    case "$(uname -m)" in
    x86_64) arch="x64" ;;
    aarch64 | arm64) arch="aarch64" ;;
    *)
        err "Unsupported architecture for the portable JDK: $(uname -m)"
        return 1
        ;;
    esac
    local jdk_url="https://api.adoptium.net/v3/binary/latest/17/ga/linux/${arch}/jdk/hotspot/normal/eclipse"
    local tools_url="https://dl.google.com/android/repository/commandlinetools-linux-13114758_latest.zip"
    local scratch jdk_file tools_file tools_tmp
    scratch="$(mktemp -d "${DATA_DIR}/.dl.XXXXXX")" || {
        err "Could not create a download directory under ${DATA_DIR}."
        return 1
    }
    TMP_DIRS+=("${scratch}")
    jdk_file="${scratch}/jdk.tar.gz"
    tools_file="${scratch}/cmdline-tools.zip"
    tools_tmp="${scratch}/tools"
    mkdir -p "${BUILD_ENV_DIR}/jdk" "${BUILD_ENV_DIR}/android-sdk"

    info "Downloading JDK 17 (${arch})..."
    if ! fetch "${jdk_url}" "${jdk_file}"; then
        err "JDK download failed."
        return 1
    fi
    tar -xzf "${jdk_file}" -C "${BUILD_ENV_DIR}/jdk" --strip-components 1 || {
        err "JDK unpack failed."
        return 1
    }
    rm -f -- "${jdk_file}"

    info "Downloading Android cmdline-tools..."
    if ! fetch "${tools_url}" "${tools_file}"; then
        err "cmdline-tools download failed."
        return 1
    fi
    mkdir -p "${tools_tmp}"
    unzip -q "${tools_file}" -d "${tools_tmp}" || {
        err "cmdline-tools unpack failed."
        return 1
    }
    rm -f -- "${tools_file}"
    mkdir -p "${BUILD_ENV_DIR}/android-sdk/cmdline-tools"
    rm -rf "${BUILD_ENV_DIR}/android-sdk/cmdline-tools/latest"
    mv -T "${tools_tmp}/cmdline-tools" \
        "${BUILD_ENV_DIR}/android-sdk/cmdline-tools/latest"
    rm -rf "${scratch}" # success: drop the scratch now (the trap is the backstop)

    info "Installing SDK packages (licenses auto-accepted)..."
    yes | "${BUILD_ENV_DIR}/android-sdk/cmdline-tools/latest/bin/sdkmanager" \
        --sdk_root="${BUILD_ENV_DIR}/android-sdk" \
        "platform-tools" "platforms;android-34" "build-tools;34.0.0" \
        >/dev/null 2>&1 || true

    {
        echo "JAVA_HOME=${BUILD_ENV_DIR}/jdk"
        echo "ANDROID_HOME=${BUILD_ENV_DIR}/android-sdk"
    } >"${ENV_PATH_FILE}"

    if [[ ! -f "${PROJECT_ROOT}/local.properties" ]]; then
        printf 'sdk.dir=%s\n' "${BUILD_ENV_DIR}/android-sdk" \
            >"${PROJECT_ROOT}/local.properties"
    fi
    ok "Portable build environment installed (${BUILD_ENV_DIR})."
}

step_apk() {
    local candidates=(
        "${PROJECT_ROOT}/app/build/outputs/apk/release/app-release.apk"
        "${PROJECT_ROOT}/app/build/outputs/apk/release/micsource-release.apk"
        "${PROJECT_ROOT}/app/build/outputs/apk/debug/app-debug.apk"
        "${STAGED_APK}"
    )
    local apk="" c
    for c in "${candidates[@]}"; do
        if [[ -f "$c" ]]; then
            apk="$c"
            break
        fi
    done

    if [[ -z "${apk}" ]]; then
        warn "No MicSource APK found (prebuilt or previous build output)."
        if ! confirm "Build it now from source with Gradle?"; then
            info "Skipping APK staging; place a prebuilt APK and re-run install.sh."
            return 2
        fi
        env_set_if_portable
        if [[ -n "${JAVA_HOME:-}" && -x "${JAVA_HOME}/bin/java" ]]; then
            export PATH="${JAVA_HOME}/bin:${PATH}"
        fi
        if [[ ! -f "${PROJECT_ROOT}/gradlew" ]]; then
            err "${PROJECT_ROOT}/gradlew not found."
            return 1
        fi
        local task="assembleDebug"
        [[ -f "${PROJECT_ROOT}/keystore.properties" ]] && task="assembleRelease"
        info "Running ./gradlew ${task} (this can take a few minutes)..."
        (cd "${PROJECT_ROOT}" && ./gradlew "${task}" --no-daemon) || {
            err "Gradle build failed (is a JDK 17 configured?)."
            return 1
        }
        for c in \
            "${PROJECT_ROOT}/app/build/outputs/apk/release/app-release.apk" \
            "${PROJECT_ROOT}/app/build/outputs/apk/release/micsource-release.apk" \
            "${PROJECT_ROOT}/app/build/outputs/apk/debug/app-debug.apk"; do
            if [[ -f "$c" ]]; then
                apk="$c"
                break
            fi
        done
        if [[ -z "${apk}" ]]; then
            err "Build finished but no APK output found."
            return 1
        fi
    fi

    # Avoid "cp: same file" noise when the staged APK is the only candidate.
    if [[ "$(readlink -f "${apk}")" != "$(readlink -f "${STAGED_APK}")" ]]; then
        cp -f "${apk}" "${STAGED_APK}"
    fi
    printf '%s\n' "${apk}" >"${APK_PATH_FILE}"
    ok "APK staged: ${STAGED_APK} (from ${apk})"
}

step_device() {
    local adb_bin
    adb_bin="$(cat "${ADB_PATH_FILE}" 2>/dev/null || echo "")"
    if [[ -z "${adb_bin}" || ! -x "${adb_bin}" ]]; then
        warn "adb unavailable; skipping device setup."
        return 2
    fi

    local state
    state="$("${adb_bin}" get-state 2>/dev/null || true)"
    if [[ "${state}" != "device" ]]; then
        warn "No Android device online (state: ${state:-none})."
        info "Connect the phone, enable USB debugging, authorize the host, then run:"
        info "  micsource install-apk   # install + forward"
        return 2
    fi
    info "Installing APK on the device..."
    if "${adb_bin}" install -r -t "${STAGED_APK}"; then
        ok "APK installed on device."
    else
        warn "adb install failed; the device may refuse unknown signers."
    fi
    "${adb_bin}" shell am start -n "${ANDROID_PKG}/.MainActivity" \
        >/dev/null 2>&1 || true
    if "${adb_bin}" forward "localabstract:${HOST_SOCKET}" \
        "localabstract:${DEVICE_SOCKET}" >/dev/null 2>&1; then
        ok "adb forward set: localabstract:${HOST_SOCKET} -> localabstract:${DEVICE_SOCKET}"
        return 0
    fi
    warn "adb forward failed; the host cannot reach the phone mic yet."
    info "  micsource install-apk   # retry install + forward"
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
        cat >"${AUTOSTART_FILE}" <<AUTOEOF
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
    # Probe the same bindings the tray script tries: the classic
    # AppIndicator3 first, then the maintained ayatana fork (see
    # micsource-tray.py).
    if ! python3 -c 'import gi
gi.require_version("Gtk", "3.0")
try:
    gi.require_version("AppIndicator3", "0.1")
    from gi.repository import AppIndicator3  # noqa: F401
except (ImportError, ValueError):
    gi.require_version("AyatanaAppIndicator3", "0.1")
    from gi.repository import AyatanaAppIndicator3  # noqa: F401' >/dev/null 2>&1; then
        warn "The GTK/AppIndicator Python bindings are not installed; the tray"
        info "will fall back to opening the control window. Install them, e.g."
        info "  sudo apt install gir1.2-gtk-3.0 gir1.2-ayatanaappindicator3-0.1"
        info "On GNOME (without appindicator), use the quick settings pill instead."
    fi
}

step_systemd() {
    cat >"${UNIT_FILE}" <<UNITEOF
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
    run_step build_env step_build_env
    run_step apk step_apk
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
