#!/usr/bin/env bash
#
# install.sh - MicSource Linux host installer
#
# Installs the host side of MicSource (a fork of the AudioSource Android
# app) into your user account (no root):
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
GNOME_EXT_UUID="micsource-tile@micsource.local"
GNOME_EXT_DIR="${HOME}/.local/share/gnome-shell/extensions/${GNOME_EXT_UUID}"
PULSE_LOCK_CONF="${HOME}/.config/pipewire/pipewire-pulse.conf.d/10-micsource-stream-lock.conf"

CONFIG_PATH="${CONFIG_DIR}/config.ini"
DATA_ICON="${DATA_DIR}/micsource-icon.svg"
ICON_PATH="${ICON_THEME_DIR}/${APP_NAME}.svg"
DESKTOP_FILE="${APPS_DIR}/${APP_NAME}.desktop"
AUTOSTART_FILE="${HOME}/.config/autostart/micsource-tray.desktop"
UNIT_FILE="${SYSTEMD_USER_DIR}/${APP_NAME}.service"
BIN_LINK="${HOME}/.local/bin/${APP_NAME}"
ADB_LINK="${HOME}/.local/bin/adb"

CLI_PATH="${DATA_DIR}/${APP_NAME}"
APP_PATH="${DATA_DIR}/micsource-app.py"
TRAY_PATH="${DATA_DIR}/micsource-tray.py"
GUI_PATH="${DATA_DIR}/micsource-gui"
BUILD_PATH="${DATA_DIR}/micsource-build"
MON_PATH="${DATA_DIR}/micsource-monitor.py"
ADB_PATH_FILE="${DATA_DIR}/adb.path"
APK_PATH_FILE="${DATA_DIR}/apk.path"
ENV_PATH_FILE="${DATA_DIR}/build-env.path"
BUILD_ENV_DIR="${DATA_DIR}/build-env"
ADB_BUNDLE_DIR="${DATA_DIR}/adb-bundle"
STAGED_APK="${DATA_DIR}/micsource-release.apk"

ANDROID_PKG="fr.dzx.audiosource"   # Android package (baked into the APK)
DEVICE_SOCKET="audiosource"        # device-side socket (RecordThread)
HOST_SOCKET="${APP_NAME}"          # host side of the adb forward

WITH_TRAY=0
for arg in "$@"; do
    case "${arg}" in
        --with-tray) WITH_TRAY=1 ;;
        -h|--help)
            cat <<USAGE
Usage: install.sh [--with-tray]

  --with-tray  enable the legacy tray icon at login (XDG autostart).
               Without the flag the tray stays opt-in; enable it from the
               control window's Preferences at any time.
USAGE
            exit 0 ;;
    esac
done

RED=$'\e[31m'; GRN=$'\e[32m'; YLW=$'\e[33m'; BLU=$'\e[34m'; BLD=$'\e[1m'; RST=$'\e[0m'

info()  { printf '%s[INFO]%s  %s\n' "$BLU" "$RST" "$*"; }
ok()    { printf '%s[OK]%s   %s\n' "$GRN" "$RST" "$*"; }
warn()  { printf '%s[WARN]%s %s\n' "$YLW" "$RST" "$*"; }
err()   { printf '%s[ERR]%s  %s\n' "$RED" "$RST" "$*" >&2; }
ask()   { printf '%s[?]%s  %s ' "$YLW" "$RST" "$*"; }

have_cmd() { command -v "$1" >/dev/null 2>&1; }

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

step_sanity() {
    if [[ "$EUID" -eq 0 ]]; then
        err "Do not run this installer as root. Run it as your normal user."
        exit 1
    fi
    mkdir -p "${DATA_DIR}" "${CONFIG_DIR}" "${APPS_DIR}" \
             "${SYSTEMD_USER_DIR}" "${ICON_THEME_DIR}" \
             "$(dirname "${GNOME_EXT_DIR}")" "${HOME}/.local/bin"
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
            return 1
        fi
        if ! have_cmd unzip; then
            err "'unzip' is required to unpack the bundle; install it and re-run."
            return 1
        fi
        have_cmd curl || have_cmd wget || { err "Need curl or wget."; return 1; }
        local url zip tmp
        url="https://dl.google.com/android/repository/platform-tools-latest-linux.zip"
        zip="${DATA_DIR}/.platform-tools.zip"
        tmp="${DATA_DIR}/.platform-tools.$$"
        mkdir -p "${tmp}"
        info "Downloading platform-tools..."
        if have_cmd curl; then
            curl -fL --retry 2 -o "${zip}" "${url}" || {
                rm -rf "${tmp}"; rm -f -- "${zip}"; err "Download failed."; return 1; }
        else
            wget -q -O "${zip}" "${url}" || {
                rm -rf "${tmp}"; rm -f -- "${zip}"; err "Download failed."; return 1; }
        fi
        unzip -q "${zip}" -d "${tmp}" || {
            rm -rf "${tmp}"; rm -f -- "${zip}"; err "Unpack failed."; return 1; }
        rm -f -- "${zip}"
        mkdir -p "${ADB_BUNDLE_DIR}"
        if [[ -d "${ADB_BUNDLE_DIR}/platform-tools" ]]; then
            warn "Existing platform-tools found; replacing."
            rm -rf "${ADB_BUNDLE_DIR}/platform-tools"
        fi
        mv -T "${tmp}/platform-tools" "${ADB_BUNDLE_DIR}/platform-tools"
        rm -rf "${tmp}"
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

    printf '%s\n' "${adb_bin}" > "${ADB_PATH_FILE}"

    case ":${PATH}:" in
        *:"${HOME}/.local/bin":*) : ;;
        *) warn "${HOME}/.local/bin is not on your PATH."
           info "Add it permanently:  export PATH=\"${HOME}/.local/bin:\$PATH\"" ;;
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
    if [[ ! -n "${ANDROID_HOME:-}" && -f "${PROJECT_ROOT}/local.properties" ]]; then
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
        return 1
    fi
    have_cmd curl || have_cmd wget || { err "Need curl or wget."; return 1; }
    local arch out_file
    case "$(uname -m)" in
        x86_64) arch="x64" ;;
        aarch64|arm64) arch="aarch64" ;;
        *) err "Unsupported architecture for the portable JDK: $(uname -m)"; return 1 ;;
    esac
    local jdk_url="https://api.adoptium.net/v3/binary/latest/17/ga/linux/${arch}/jdk/hotspot/normal/eclipse"
    local tools_url="https://dl.google.com/android/repository/commandlinetools-linux-13114758_latest.zip"
    mkdir -p "${BUILD_ENV_DIR}/jdk" "${BUILD_ENV_DIR}/android-sdk"

    info "Downloading JDK 17 (${arch})..."
    out_file="${DATA_DIR}/.jdk.tar.gz"
    if have_cmd curl; then
        curl -fL --retry 2 -o "${out_file}" "${jdk_url}" || {
            rm -f -- "${out_file}"; err "JDK download failed."; return 1; }
    else
        wget -q -O "${out_file}" "${jdk_url}" || {
            rm -f -- "${out_file}"; err "JDK download failed."; return 1; }
    fi
    tar -xzf "${out_file}" -C "${BUILD_ENV_DIR}/jdk" --strip-components 1 || {
        rm -f -- "${out_file}"; err "JDK unpack failed."; return 1; }
    rm -f -- "${out_file}"

    info "Downloading Android cmdline-tools..."
    out_file="${DATA_DIR}/.cmdline-tools.zip"
    if have_cmd curl; then
        curl -fL --retry 2 -o "${out_file}" "${tools_url}" || {
            rm -f -- "${out_file}"; err "cmdline-tools download failed."; return 1; }
    else
        wget -q -O "${out_file}" "${tools_url}" || {
            rm -f -- "${out_file}"; err "cmdline-tools download failed."; return 1; }
    fi
    local tools_tmp="${DATA_DIR}/.tools-tmp.$$"
    mkdir -p "${tools_tmp}"
    unzip -q "${out_file}" -d "${tools_tmp}" || {
        rm -rf "${tools_tmp}"; rm -f -- "${out_file}"; err "cmdline-tools unpack failed."; return 1; }
    rm -f -- "${out_file}"
    mkdir -p "${BUILD_ENV_DIR}/android-sdk/cmdline-tools"
    rm -rf "${BUILD_ENV_DIR}/android-sdk/cmdline-tools/latest"
    mv -T "${tools_tmp}/cmdline-tools" \
          "${BUILD_ENV_DIR}/android-sdk/cmdline-tools/latest"
    rm -rf "${tools_tmp}"

    info "Installing SDK packages (licenses auto-accepted)..."
    yes | "${BUILD_ENV_DIR}/android-sdk/cmdline-tools/latest/bin/sdkmanager" \
        --sdk_root="${BUILD_ENV_DIR}/android-sdk" \
        "platform-tools" "platforms;android-34" "build-tools;34.0.0" \
        >/dev/null 2>&1 || true

    {
        echo "JAVA_HOME=${BUILD_ENV_DIR}/jdk"
        echo "ANDROID_HOME=${BUILD_ENV_DIR}/android-sdk"
    } > "${ENV_PATH_FILE}"

    if [[ ! -f "${PROJECT_ROOT}/local.properties" ]]; then
        printf 'sdk.dir=%s\n' "${BUILD_ENV_DIR}/android-sdk" \
            > "${PROJECT_ROOT}/local.properties"
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
        if [[ -f "$c" ]]; then apk="$c"; break; fi
    done

    if [[ -z "${apk}" ]]; then
        warn "No MicSource APK found (prebuilt or previous build output)."
        if ! confirm "Build it now from source with Gradle?"; then
            info "Skipping APK staging; place a prebuilt APK and re-run install.sh."
            return 1
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
            if [[ -f "$c" ]]; then apk="$c"; break; fi
        done
        if [[ -z "${apk}" ]]; then
            err "Build finished but no APK output found."
            return 1
        fi
    fi

    cp -f "${apk}" "${STAGED_APK}"
    printf '%s\n' "${apk}" > "${APK_PATH_FILE}"
    ok "APK staged: ${STAGED_APK} (from ${apk})"
}

step_device() {
    local adb_bin
    adb_bin="$(cat "${ADB_PATH_FILE}" 2>/dev/null || echo "")"
    if [[ -z "${adb_bin}" || ! -x "${adb_bin}" ]]; then
        warn "adb unavailable; skipping device setup."
        return 1
    fi

    local state
    state="$("${adb_bin}" get-state 2>/dev/null || true)"
    if [[ "${state}" != "device" ]]; then
        warn "No Android device online (state: ${state:-none})."
        info "Connect the phone, enable USB debugging, authorize the host, then run:"
        info "  micsource install-apk   # install + forward"
        return 1
    fi
    info "Installing APK on the device..."
    if "${adb_bin}" install -r -t "${STAGED_APK}"; then
        ok "APK installed on device."
    else
        warn "adb install failed; the device may refuse unknown signers."
    fi
    "${adb_bin}" shell am start -n "${ANDROID_PKG}/.MainActivity" \
        >/dev/null 2>&1 || true
    "${adb_bin}" forward "localabstract:${HOST_SOCKET}" \
        "localabstract:${DEVICE_SOCKET}" >/dev/null 2>&1 || true
    ok "adb forward set: localabstract:${HOST_SOCKET} -> localabstract:${DEVICE_SOCKET}"
}

step_config() {
    if [[ -f "${CONFIG_PATH}" ]]; then
        ok "Existing config preserved: ${CONFIG_PATH}"
        return 0
    fi
    cat > "${CONFIG_PATH}" <<'CONF'
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
    chmod 600 "${CONFIG_PATH}"
    ok "Config written: ${CONFIG_PATH}"
}

step_desktop() {
    local icon_name="micsource"

        cat > "${DATA_ICON}" <<'__ICONEOF__'
<?xml version="1.0" encoding="UTF-8" standalone="no"?>
<svg
   xmlns:dc="http://purl.org/dc/elements/1.1/"
   xmlns:cc="http://creativecommons.org/ns#"
   xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
   xmlns:svg="http://www.w3.org/2000/svg"
   xmlns="http://www.w3.org/2000/svg"
   xmlns:sodipodi="http://sodipodi.sourceforge.net/DTD/sodipodi-0.dtd"
   xmlns:inkscape="http://www.inkscape.org/namespaces/inkscape"
   inkscape:version="1.0.1 (3bc2e813f5, 2020-09-07, custom)"
   sodipodi:docname="audiosource.svg"
   id="svg2849"
   viewBox="0 0 24 24"
   height="24"
   width="24"
   version="1.1">
  <path
     id="path3311"
     style="color:#000000;font-style:normal;font-variant:normal;font-weight:normal;font-stretch:normal;font-size:medium;line-height:normal;font-family:sans-serif;font-variant-ligatures:normal;font-variant-position:normal;font-variant-caps:normal;font-variant-numeric:normal;font-variant-alternates:normal;font-variant-east-asian:normal;font-feature-settings:normal;font-variation-settings:normal;text-indent:0;text-align:start;text-decoration:none;text-decoration-line:none;text-decoration-style:solid;text-decoration-color:#000000;letter-spacing:normal;word-spacing:normal;text-transform:none;writing-mode:lr-tb;direction:ltr;text-orientation:mixed;dominant-baseline:auto;baseline-shift:baseline;text-anchor:start;white-space:normal;shape-padding:0;shape-margin:0;inline-size:0;clip-rule:nonzero;display:inline;overflow:visible;visibility:visible;opacity:1;isolation:auto;mix-blend-mode:normal;color-interpolation:sRGB;color-interpolation-filters:linearRGB;solid-color:#000000;solid-opacity:1;vector-effect:none;fill:#ffffff;fill-opacity:1;fill-rule:nonzero;stroke:none;stroke-width:2.14286;stroke-linecap:butt;stroke-linejoin:round;stroke-miterlimit:3.6;stroke-dasharray:none;stroke-dashoffset:0;stroke-opacity:1;color-rendering:auto;image-rendering:auto;shape-rendering:auto;text-rendering:auto;enable-background:accumulate;stop-color:#000000;stop-opacity:1"
     d="M 12 2 C 9.8235712 2 8.0722656 3.7513059 8.0722656 5.9277344 L 8.0722656 10.927734 C 8.0722656 13.104163 9.8235712 14.857422 12 14.857422 C 14.176429 14.857422 15.927734 13.104163 15.927734 10.927734 L 15.927734 5.9277344 C 15.927734 3.7513059 14.176429 2 12 2 z M 4.5 10.927734 C 4.4999999 13.605509 5.9309794 16.084941 8.25 17.423828 C 9.088771 17.908093 9.9982874 18.211748 10.927734 18.345703 L 10.927734 19.857422 L 8.7851562 19.857422 L 8.7851562 22 L 15.214844 22 L 15.214844 19.857422 L 13.072266 19.857422 L 13.072266 18.345703 C 14.001713 18.211748 14.911229 17.908093 15.75 17.423828 C 18.069021 16.084941 19.5 13.605509 19.5 10.927734 L 17.357422 10.927734 C 17.357422 12.843375 16.336728 14.610538 14.677734 15.568359 C 13.018741 16.526179 10.981259 16.526179 9.3222656 15.568359 C 7.6632716 14.610538 6.6425781 12.843375 6.6425781 10.927734 L 4.5 10.927734 z " />
  <metadata
     id="metadata2855">
    <rdf:RDF>
      <cc:Work
         rdf:about="">
        <dc:format>image/svg+xml</dc:format>
        <dc:type
           rdf:resource="http://purl.org/dc/dcmitype/StillImage" />
        <dc:title></dc:title>
      </cc:Work>
    </rdf:RDF>
  </metadata>
  <defs
     id="defs2853" />
  <sodipodi:namedview
     inkscape:current-layer="svg2849"
     inkscape:window-maximized="1"
     inkscape:window-y="1236"
     inkscape:window-x="6"
     inkscape:cy="12.265586"
     inkscape:cx="10.697683"
     inkscape:zoom="23.997436"
     inkscape:object-nodes="false"
     inkscape:snap-others="false"
     inkscape:bbox-nodes="true"
     inkscape:bbox-paths="true"
     inkscape:snap-bbox="true"
     fit-margin-bottom="0"
     fit-margin-right="0"
     fit-margin-left="0"
     fit-margin-top="0"
     showgrid="true"
     id="namedview2851"
     inkscape:window-height="1034"
     inkscape:window-width="1904"
     inkscape:pageshadow="2"
     inkscape:pageopacity="0"
     guidetolerance="10"
     gridtolerance="10"
     objecttolerance="10"
     borderopacity="1"
     bordercolor="#666666"
     pagecolor="#ffffff"
     inkscape:document-rotation="0">
    <inkscape:grid
       id="grid2857"
       type="xygrid" />
  </sodipodi:namedview>
</svg>
__ICONEOF__

    if [[ -f "${DATA_ICON}" ]]; then
        cp -f "${DATA_ICON}" "${ICON_PATH}"
        ok "App icon installed: ${ICON_PATH}"
    elif [[ -f "${PROJECT_ROOT}/assets/icon.svg" ]]; then
        cp -f "${PROJECT_ROOT}/assets/icon.svg" "${ICON_PATH}"
        ok "App icon installed (repo asset): ${ICON_PATH}"
    else
        icon_name="audio-input-microphone"
        warn "No SVG icon found; the launcher falls back to the themed mic icon."
    fi

    cat > "${DESKTOP_FILE}" <<DESKEOF
[Desktop Entry]
Type=Application
Name=MicSource
GenericName=Phone Microphone over USB
Comment=Use your Android phone as a PC microphone (adb forwarded PCM stream)
Exec=${GUI_PATH}
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
        cat > "${CLI_PATH}" <<'__CLIEOF__'
#!/usr/bin/env bash
#
# micsource - command-line client for the MicSource Linux host suite.
#
# Generated by linux-install/install.sh and linked from ~/.local/bin/micsource.
#
# Commands:
#   start        Start the background monitor service (systemd if available)
#   stop         Stop the monitor
#   status       Show service / device / socket-forward status
#   run          Foreground: set up the forward and stream audio until Ctrl+C
#   tray         Launch the system tray icon (background)
#   install-apk  (Re)install the staged APK on the device + set up forward
#   config       Open the config folder
#   help         Show this help
#
set -euo pipefail

APP_NAME="micsource"
DATA_DIR="${HOME}/.local/share/micsource"
CONFIG_DIR="${HOME}/.config/micsource"
APK_STAGED="${DATA_DIR}/micsource-release.apk"
TRAY_PATH="${DATA_DIR}/micsource-tray.py"
MONITOR_PATH="${DATA_DIR}/micsource-monitor.py"
GUI_PATH="${DATA_DIR}/micsource-gui"
BUILD_PATH="${DATA_DIR}/micsource-build"
CTL_SOCK="${DATA_DIR}/micsource.sock"
SYSTEMD_UNIT="${HOME}/.config/systemd/user/micsource.service"
ANDROID_PKG="fr.dzx.audiosource"   # Android package (baked into the APK)
DEVICE_SOCKET="audiosource"        # device-side socket (RecordThread)
HOST_SOCKET="micsource"            # host side of the adb forward

info() { printf '[INFO] %s\n' "$*"; }
err()  { printf '[ERR]  %s\n' "$*" >&2; }

have_cmd() { command -v "$1" >/dev/null 2>&1; }

usage() {
    cat <<HELP
Usage: micsource <command>

Commands:
  start        Start the background monitor service (systemd if available)
  stop         Stop the monitor
  status       Show service / device / socket-forward status
  run          Foreground: set up the forward and stream audio until Ctrl+C
  tray         Launch the system tray icon (background)
  window       Open the desktop control window
  build-apk    Build the APK from source and stage it (uses managed JDK/SDK)
  install-apk  (Re)install the staged APK on the device + set up forward
  config       Open the config folder
  help         Show this help
HELP
}

resolve_adb() {
    local candidate=""
    if [[ -f "${CONFIG_DIR}/config.ini" ]]; then
        candidate="$(awk -F= '/^[[:space:]]*adb_path[[:space:]]*=/ {sub(/^[[:space:]]+/, "", $2); print $2}' \
            "${CONFIG_DIR}/config.ini" | head -n 1)"
    fi
    if [[ -z "$candidate" && -f "${DATA_DIR}/adb.path" ]]; then
        candidate="$(tr -d '\n' < "${DATA_DIR}/adb.path")"
    fi
    if [[ -n "$candidate" && -x "$candidate" ]]; then
        echo "$candidate"
        return 0
    fi
    if [[ -x "${DATA_DIR}/adb-bundle/platform-tools/adb" ]]; then
        echo "${DATA_DIR}/adb-bundle/platform-tools/adb"
        return 0
    fi
    command -v adb || true
}

service_start() {
    if have_cmd systemctl; then
        if [[ ! -f "${SYSTEMD_UNIT}" ]]; then
            err "Service not installed; run install.sh first."
            exit 1
        fi
        systemctl --user enable --now --quiet "${APP_NAME}.service" 2>/dev/null \
            || systemctl --user start "${APP_NAME}.service"
        info "Monitor service started."
    else
        if [[ ! -f "${MONITOR_PATH}" ]]; then
            err "Monitor not installed; run install.sh first."
            exit 1
        fi
        "${MONITOR_PATH}" >/dev/null 2>&1 &
        info "Monitor started in the background (systemd not available)."
    fi
}

service_stop() {
    if have_cmd systemctl; then
        systemctl --user stop "${APP_NAME}.service" 2>/dev/null || true
    fi
    if have_cmd pkill && [[ -f "${MONITOR_PATH}" ]]; then
        pkill -f -- "${MONITOR_PATH}" 2>/dev/null || true
        # Let the monitor exit gracefully first: on SIGTERM it unloads the
        # virtual mic sources and player processes before dying.
        local i
        for i in 1 2 3 4 5 6 7 8 9 10; do
            pkill -0 -f -- "${MONITOR_PATH}" 2>/dev/null || break
            sleep 1
        done
        if pkill -0 -f -- "${MONITOR_PATH}" 2>/dev/null; then
            warn "monitor did not exit; sending SIGKILL"
            pkill -9 -f -- "${MONITOR_PATH}" 2>/dev/null || true
        fi
    fi
    info "Monitor stopped."
}

query_status() {
    # 1) Ask the running monitor via its control socket (if any).
    if [[ -S "${CTL_SOCK}" ]]; then
        local monitor_resp=""
        monitor_resp="$(python3 -c '
import socket, sys
try:
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(2)
    s.connect(sys.argv[1])
    s.sendall(b"status")
    print(s.recv(256).decode(errors="ignore").strip())
except Exception:
    pass
' "${CTL_SOCK}" || true)"
        if [[ -n "$monitor_resp" ]]; then
            info "monitor: ${monitor_resp}"
        else
            info "monitor: not responding"
        fi
    else
        info "monitor: not running"
    fi

    # 2) systemd unit state
    if have_cmd systemctl && [[ -f "${SYSTEMD_UNIT}" ]]; then
        local active
        active="$(systemctl --user is-active "${APP_NAME}.service" 2>/dev/null || true)"
        info "systemd unit: ${active:-unknown}"
    fi

    # 3) adb device + forward state
    local adb_bin state forward_list
    adb_bin="$(resolve_adb)"
    if [[ -z "$adb_bin" ]]; then
        info "adb: not found; run install.sh to install the adb bundle"
        return 0
    fi
    state="$("$adb_bin" get-state 2>/dev/null || true)"
    info "adb device state: ${state:-none}"
    forward_list="$("$adb_bin" forward --list 2>/dev/null || true)"
    if [[ "$forward_list" == *localabstract:"${HOST_SOCKET}"* ]]; then
        info "socket forward: active (localabstract:${HOST_SOCKET} -> localabstract:${DEVICE_SOCKET})"
    else
        info "socket forward: not set"
    fi
}

one_shot_run() {
    if [[ ! -f "${MONITOR_PATH}" ]]; then
        err "Monitor not installed; run install.sh first."
        exit 1
    fi
    exec python3 "${MONITOR_PATH}" --run
}

build_apk() {
    if [[ ! -f "${BUILD_PATH}" ]]; then
        err "Build helper not installed; run install.sh first."
        exit 1
    fi
    exec bash "${BUILD_PATH}"
}

launch_window() {
    if [[ ! -f "${GUI_PATH}" ]]; then
        err "Control window not installed; run install.sh first."
        exit 1
    fi
    exec "${GUI_PATH}"
}

launch_tray() {
    if [[ ! -f "${TRAY_PATH}" ]]; then
        err "Tray not installed; run install.sh first."
        exit 1
    fi
    "${TRAY_PATH}" --tray >/dev/null 2>&1 &
    info "Tray launched."
}

device_install() {
    local adb_bin
    adb_bin="$(resolve_adb)"
    if [[ -z "$adb_bin" ]]; then
        err "adb not found; run install.sh to install the adb bundle."
        exit 1
    fi
    if [[ ! -f "${APK_STAGED}" ]]; then
        err "No staged APK at ${APK_STAGED}."
        info "Place a prebuilt APK there (see docs/USER.md) or re-run install.sh after building."
        exit 1
    fi
    local install_out=""
    if ! install_out="$("$adb_bin" install -r -t "${APK_STAGED}" 2>&1)"; then
        if [[ "$install_out" == *INSTALL_FAILED_UPDATE_INCOMPATIBLE* ]]; then
            err "The device already has a differently-signed ${ANDROID_PKG}"
            err "(e.g. the upstream release build); our APK cannot update it."
            warn "Replacing it will UNINSTALL the existing app from the device"
            warn "(together with its settings data)."
            local ans=""
            ask "Uninstall the existing app and install ours? [y/N] "
            read -r ans || true
            case "$ans" in
                y|Y|yes)
                    if ! "$adb_bin" uninstall "${ANDROID_PKG}"; then
                        err "Could not uninstall the existing app."
                        exit 1
                    fi
                    if ! "$adb_bin" install -r -t "${APK_STAGED}"; then
                        err "adb install failed even after uninstall."
                        exit 1
                    fi
                    ;;
                *)
                    info "Device install skipped. The existing (differently-signed)"
                    info "app on the device keeps working normally."
                    exit 1
                    ;;
            esac
        else
            err "adb install failed: ${install_out}"
            exit 1
        fi
    fi
    "$adb_bin" shell am force-stop "${ANDROID_PKG}" >/dev/null 2>&1 || true
    "$adb_bin" shell am start -n "${ANDROID_PKG}/.MainActivity" >/dev/null 2>&1 || true
    "$adb_bin" forward --remove "localabstract:${HOST_SOCKET}" >/dev/null 2>&1 || true
    if "$adb_bin" forward "localabstract:${HOST_SOCKET}" "localabstract:${DEVICE_SOCKET}"; then
        info "Forward active: localabstract:${HOST_SOCKET} -> localabstract:${DEVICE_SOCKET}"
    else
        err "Could not create the socket forward (app not running?)."
        exit 1
    fi
    info "APK installed."
}

open_config() {
    if have_cmd xdg-open; then
        xdg-open "${CONFIG_DIR}" >/dev/null 2>&1 || true
        info "Opened ${CONFIG_DIR}"
    else
        info "Config folder: ${CONFIG_DIR}"
    fi
}

command="${1:-help}"
case "$command" in
    start)         service_start ;;
    stop)          service_stop ;;
    status)        query_status ;;
    run)           one_shot_run ;;
    tray)          launch_tray ;;
    window)        launch_window ;;
    build-apk)     build_apk ;;
    install-apk)   device_install ;;
    config)        open_config ;;
    help|--help|-h) usage ;;
    *) err "Unknown command: ${command}"; usage >&2; exit 2 ;;
esac
__CLIEOF__
    chmod +x "${CLI_PATH}"

        cat > "${APP_PATH}" <<'__APPEOF__'
#!/usr/bin/env python3
"""
MicSource desktop control window (GTK 4 + libadwaita).

Launched from the app drawer (via the micsource-gui wrapper), the CLI
(`micsource window`), or the GNOME top-bar tile's "Open Control Window".

The main window shows device + monitoring status (the Monitoring row
carries a real-time input level bar fed by the background service's
metering — no extra capture stream), and the same actions as the
micsource CLI:

  * Start / Stop the background service (the only audio pump)
  * Install the staged APK on the device
  * Open the config folder
  * Build the APK from source

The header menu opens a Preferences dialog (Adw.PreferencesDialog when
libadwaita >= 1.5 is available, Adw.PreferencesWindow otherwise) with
instant-apply switches per the GNOME HIG:

  * Auto-start service at login        (systemd user unit enable/disable)
  * GNOME top-bar tile                 (gnome-extensions enable/disable)
  * Tray icon (AppIndicator, opt-in)   (XDG autostart entry + spawn/kill —
    legacy tray for KDE/XFCE/etc.; GNOME users should use the tile)
  * Virtual microphone / play to       (~/.config/micsource/config.ini;
    speakers                            applied on next service start)

Also sends desktop notifications on state changes (device link, install
results, service state). The tray icon stays on Gtk 3 because the
AppIndicator/Ayatana client bindings are Gtk 3 only.
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

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
from gi.repository import Adw, Gio, GLib, Gtk  # noqa: E402

APP_TITLE = "MicSource"
SYSTEMD_UNIT = "micsource.service"
EXT_ID = "micsource-tile@micsource.local"
DATA_DIR = os.path.expanduser("~/.local/share/micsource")
CONFIG_DIR = os.path.expanduser("~/.config/micsource")
CONFIG_PATH = os.path.join(CONFIG_DIR, "config.ini")
ADB_PATH_FILE = os.path.join(DATA_DIR, "adb.path")
CLI_PATH = os.path.join(DATA_DIR, "micsource")
BUILD_PATH = os.path.join(DATA_DIR, "micsource-build")
TRAY_PATH = os.path.join(DATA_DIR, "micsource-tray.py")
TRAY_DESKTOP = os.path.expanduser("~/.config/autostart/micsource-tray.desktop")
UNIT_FILE = os.path.expanduser(f"~/.config/systemd/user/{SYSTEMD_UNIT}")

ANDROID_PKG = "fr.dzx.audiosource"  # Android package (baked into the APK)
DEVICE_SOCKET = "audiosource"       # device-side socket (RecordThread)
DEFAULT_HOST_SOCKET = "micsource"   # host side of the adb forward

last_notified = None

ADB_CMD = "adb"
SERIAL = None
HOST_SOCKET = DEFAULT_HOST_SOCKET


def _log(msg):
    print(f"[micsource-app] {msg}", flush=True)


def _load_config():
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
    """Control window (Adwaita): status, service, install, build, prefs."""

    def __init__(self):
        super().__init__(application_id="local.micsource")
        # NON_UNIQUE: each launch is its own primary instance. The default
        # (unique) behavior hands activation off to whatever stale or
        # crashed instance still holds the bus name -- and the new process
        # exits silently without ever showing a window.
        self.set_flags(Gio.ApplicationFlags.NON_UNIQUE)
        self.window = None
        self.row_device = None
        self.row_monitor = None
        self.row_error = None
        self.log_view = None
        self.log_buffer = None
        self.btn_service_start = None
        self.btn_service_stop = None
        self.btn_install = None
        self.btn_build = None
        self._pref = None          # open preferences dialog/window (toasts)
        self.meter = None          # input level bar (Monitoring row suffix)
        self._meter_value = 0.0    # last level reported by the service
        self._meter_on = False     # meter polling thread flag

        act = Gio.SimpleAction.new("preferences", None)
        act.connect("activate", self._on_preferences_action)
        self.add_action(act)
        act = Gio.SimpleAction.new("about", None)
        act.connect("activate", self._on_about_action)
        self.add_action(act)

    # ------------------------------------------------------------------
    # UI construction (libadwaita)
    # ------------------------------------------------------------------
    def do_activate(self):
        self.window = Adw.ApplicationWindow(application=self)
        # Adaptive sizing: the content scroll page below keeps the window
        # usable at any height (GNOME HIG); 420x540 is just the default.
        self.window.set_default_size(420, 540)

        # Header bar (standard Adwaita window layout) + primary menu.
        header = Adw.HeaderBar(
            title_widget=Adw.WindowTitle(title="MicSource",
                                         subtitle="phone mic over USB"))
        menu_btn = Gtk.MenuButton()
        menu_btn.set_icon_name("open-menu-symbolic")
        menu_btn.set_tooltip_text("Menu")
        menu_model = Gio.Menu()
        menu_model.append("Preferences…", "app.preferences")
        menu_model.append("About MicSource", "app.about")
        menu_btn.set_menu_model(menu_model)
        header.pack_end(menu_btn)

        content = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12)
        content.set_margin_top(12)
        content.set_margin_bottom(12)
        content.set_margin_start(12)
        content.set_margin_end(12)

        # ---- status group (Settings-style property rows) -----------------
        status_group = Adw.PreferencesGroup(title="Status")
        content.append(status_group)

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

        # ---- service controls (level pair of equal-width buttons) --------
        svc_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
        svc_box.set_homogeneous(True)
        self.btn_service_start = Gtk.Button(label="Start Service")
        self.btn_service_start.add_css_class("suggested-action")
        self.btn_service_start.connect("clicked", self.on_service_start)
        self.btn_service_stop = Gtk.Button(label="Stop Service")
        self.btn_service_stop.add_css_class("destructive-action")
        self.btn_service_stop.connect("clicked", self.on_service_stop)
        svc_box.append(self.btn_service_start)
        svc_box.append(self.btn_service_stop)
        content.append(svc_box)

        # ---- device utilities (boxed list with flat row buttons) ---------
        util_group = Adw.PreferencesGroup(title="Device")
        self._action_row_button(
            util_group, "Install APK on the Phone",
            "Installs the staged APK and restores the socket forward",
            "Install", self.on_install_apk)
        self._action_row_button(
            util_group, "Build APK from Source",
            "Compiles the project checkout (first run is slow)",
            "Build", self.on_build_apk)
        self._action_row_button(
            util_group, "Open Config Folder", "", "Open", self.on_open_config)
        content.append(util_group)

        # ---- activity log --------------------------------------------------
        self.log_view = Gtk.TextView()
        self.log_view.set_editable(False)
        self.log_view.set_cursor_visible(False)
        self.log_view.set_wrap_mode(Gtk.WrapMode.NONE)
        self.log_buffer = self.log_view.get_buffer()

        scroll = Gtk.ScrolledWindow()
        scroll.set_policy(Gtk.PolicyType.AUTOMATIC, Gtk.PolicyType.AUTOMATIC)
        scroll.set_size_request(-1, 110)
        scroll.set_child(self.log_view)

        content.append(Gtk.Label(label="Activity log", xalign=0,
                                 halign=Gtk.Align.START))
        content.append(Gtk.Frame(child=scroll))

        # Adaptive page: clamped width (HIG single-column layout like
        # gnome-settings) inside a vertical scroll, so the window works
        # at any height instead of overflowing a fixed size.
        clamp = Adw.Clamp(maximum_size=600, tightening_threshold=500)
        clamp.set_child(content)
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
        GLib.timeout_add_seconds(3, self._refresh)
        self._refresh()

    def _button(self, grid, col, row, label, handler):
        btn = Gtk.Button(label=label)
        btn.set_hexpand(True)
        btn.connect("clicked", handler)
        grid.attach(btn, col, row, 1, 1)
        return btn

    def _action_row_button(self, group, title, subtitle, label, handler):
        """HIG boxed-list row: title/subtitle with a flat button suffix.

        The row background activates the same handler (single control per
        row; the button remains visible for pointer users).
        """
        btn = Gtk.Button(label=label, valign=Gtk.Align.CENTER)
        btn.add_css_class("flat")
        if handler in (self.on_install_apk, self.on_build_apk):
            # keep the existing reference for enable/disable during work
            if handler is self.on_install_apk:
                self.btn_install = btn
            else:
                self.btn_build = btn
        btn.connect("clicked", handler)
        row = Adw.ActionRow(title=title, subtitle=subtitle)
        row.add_suffix(btn)
        row.set_activatable_widget(btn)
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
                s.connect(os.path.join(DATA_DIR, "micsource.sock"))
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
        self.log_buffer.insert(self.log_buffer.get_end_iter(), line.rstrip() + "\n")
        self.log_view.scroll_mark_onscreen(self.log_buffer.get_insert())

    def _toast(self, msg):
        """Show a toast in the preferences dialog (or log as fallback)."""
        if self._pref is not None:
            try:
                self._pref.add_toast(Adw.Toast.new(msg))
                return
            except Exception:
                pass
        self.log_line(msg)

    def _service_state(self):
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
        def worker():
            try:
                online = device_online()
                forwarded = socket_forwarded() if online else False
                service = self._service_state()
                monitor = self._query_monitor()
                # Device model name: prefer the monitor's already-resolved
                # name — its probe chain (ro.product.marketname -> model ->
                # ...) yields user-facing marketing names such as "Redmi A5"
                # instead of the raw ro.product.model code ("25028RN03A"),
                # and the monitor caches it per serial so probing stays
                # one-per-connect. Fall back to our own getprop (marketname
                # first, then model) only while the monitor is not running.
                m = re.search(r"\bname=([^\n\r]+)", monitor)
                device_name_str = m.group(1).strip() if m else ""
                if online and not device_name_str:
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
            s.connect(os.path.join(DATA_DIR, "micsource.sock"))
            s.sendall(b"status")
            # 256-byte buffer: the status line can carry name=<model>, and
            # 64 truncated it off the end (same fix the CLI got).
            resp = s.recv(256).decode(errors="ignore").strip()
            s.close()
            return resp
        except Exception:
            return ""

    def _apply_status(self, connected, device_name_str, service, err, monitor):
        """Two user-facing rows only: Device and Monitoring. The systemd
        unit name ("background service") is an implementation detail; the
        seconds counter moved to the level bar + CLI status."""
        global last_notified

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

        self.btn_service_start.set_sensitive(service != "active")
        self.btn_service_stop.set_sensitive(service == "active")

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

        # Auto-start service at login (systemd user unit).
        svc_ok = bool(shutil.which("systemctl")) and os.path.isfile(UNIT_FILE)
        svc_row, svc_watch, svc_get, svc_set = _make_switch_row(
            "Auto-start Service at Login",
            "Runs the background audio service when you log in")
        self._wire_toggle(svc_row, svc_watch, svc_get, svc_set,
                          self._get_autostart, self._apply_autostart,
                          sensitive=svc_ok,
                          unavailable="systemd unit missing (re-run install.sh)")
        grp.add(svc_row)

        # GNOME top-bar tile.
        gn_ok = bool(shutil.which("gnome-extensions"))
        tile_row, tile_watch, tile_get, tile_set = _make_switch_row(
            "GNOME Top-bar Tile",
            "MicSource status and controls in the GNOME panel")
        self._wire_toggle(tile_row, tile_watch, tile_get, tile_set,
                          self._get_tile, self._apply_tile,
                          sensitive=gn_ok,
                          unavailable="gnome-extensions not available "
                                      "on this system")
        grp.add(tile_row)

        # Opt-in AppIndicator tray (KDE/XFCE/etc.; GNOME users use the tile).
        tray_ok = os.path.isfile(TRAY_PATH)
        tray_row, tray_watch, tray_get, tray_set = _make_switch_row(
            "Tray Icon (AppIndicator)",
            "Legacy tray icon for KDE/XFCE/other desktops")
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
    def _get_autostart(self):
        rc, out = _run_cmd(["systemctl", "--user", "is-enabled", SYSTEMD_UNIT])
        return rc == 0 and out.strip() == "enabled"

    def _apply_autostart(self, on):
        args = (["systemctl", "--user", "enable", "--quiet"]
                if on else ["systemctl", "--user", "disable", "--quiet"])
        rc, out = _run_cmd(args + [SYSTEMD_UNIT])
        if rc != 0:
            return False, out or "systemctl failed"
        return True, ("service enabled at login" if on
                      else "service autostart disabled")

    def _get_tile(self):
        rc, out = _run_cmd(["gnome-extensions", "info", EXT_ID])
        if rc != 0:
            return False
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
                return state.startswith("ACTIVE")
        return False

    def _apply_tile(self, on):
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

    def _get_tray(self):
        return os.path.isfile(TRAY_DESKTOP)

    def _apply_tray(self, on):
        if on:
            os.makedirs(os.path.dirname(TRAY_DESKTOP), exist_ok=True)
            desktop = (
                "[Desktop Entry]\n"
                "Type=Application\n"
                "Name=MicSource Tray\n"
                "Comment=MicSource status icon (opens the control window "
                "when no tray is available)\n"
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
    def on_service_start(self, _btn):
        self._service_action("start")

    def on_service_stop(self, _btn):
        self._service_action("stop")

    def _service_action(self, verb):
        self.log_line(f"service: {verb}…")
        if verb == "start":
            args = ["enable", "--now", "--quiet"]
        else:
            args = ["stop"]

        def worker():
            ok = False
            out = ""
            try:
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
        return False

    def on_install_apk(self, _btn):
        if self.btn_install is not None and not self.btn_install.get_sensitive():
            return  # already running (row clicks share the same button)
        self.log_line("install-apk: running…")
        self.btn_install.set_sensitive(False)

        def worker():
            try:
                proc = subprocess.run(
                    ["bash", CLI_PATH, "install-apk"],
                    capture_output=True, text=True, timeout=240)
                out = ((proc.stdout or "") + (proc.stderr or "")).strip()
                code = proc.returncode
            except FileNotFoundError:
                code, out = 1, "micsource CLI not found; run install.sh first"
            except subprocess.TimeoutExpired as exc:
                code, out = 1, f"install-apk timed out: {exc}"
            GLib.idle_add(self._install_done, code, out)

        threading.Thread(target=worker, daemon=True).start()

    def _install_done(self, code, out):
        self.btn_install.set_sensitive(True)
        short = (out or "unknown error")[-1200:]
        if code == 0:
            self.log_line("install-apk: OK")
            self._notify("MicSource install complete",
                         "APK installed on the device; forwarding configured.")
        else:
            self.log_line(f"install-apk FAILED:\n{short}")
            self._notify("MicSource install failed", short[:200], "dialog-error")
            self._error_dialog("install-apk failed", short)
        if self.window and self.window.get_mapped():
            self._refresh()
        return False

    def on_open_config(self, _btn):
        try:
            subprocess.Popen(["xdg-open", CONFIG_DIR])
        except FileNotFoundError:
            self.log_line(f"config folder: {CONFIG_DIR}")

    def on_build_apk(self, _btn):
        if self.btn_build is not None and not self.btn_build.get_sensitive():
            return  # already running (row clicks share the same button)
        self.log_line("build-apk: running Gradle…"
                      " (first run can take several minutes)")
        self.btn_build.set_sensitive(False)

        def worker():
            try:
                proc = subprocess.run(
                    ["bash", BUILD_PATH], capture_output=True, text=True,
                    timeout=1800)
                out = ((proc.stdout or "") + (proc.stderr or "")).strip()
                code = proc.returncode
            except FileNotFoundError:
                code, out = 1, "micsource-build helper not found; run install.sh"
            except subprocess.TimeoutExpired:
                code, out = 1, "build-apk timed out"
            install_code = None
            install_out = ""
            if code == 0:
                # The build script already staged the APK; install it next.
                try:
                    iproc = subprocess.run(
                        ["bash", CLI_PATH, "install-apk"],
                        capture_output=True, text=True, timeout=240)
                    install_out = ((iproc.stdout or "") + (iproc.stderr or "")).strip()
                    install_code = iproc.returncode
                except subprocess.TimeoutExpired:
                    install_code, install_out = 1, "install-apk timed out"
                except FileNotFoundError:
                    install_code, install_out = 1, "micsource CLI not found"
            GLib.idle_add(self._build_done, code, out, install_code, install_out)

        threading.Thread(target=worker, daemon=True).start()

    def _build_done(self, code, out, install_code, install_out):
        self.btn_build.set_sensitive(True)
        short = (out or "unknown error")[-1500:]
        if code == 0:
            self.log_line("build-apk: OK (APK staged)")
            self._notify("MicSource build complete",
                         "APK built from source and staged.")
            if install_code is not None:
                if install_code == 0:
                    self.log_line("install-apk: OK (device install + forward)")
                    self._notify("MicSource install complete",
                                 "New APK installed on the device.")
                else:
                    self.log_line(f"install-apk FAILED:\n{install_out[-800:]}")
                    self._notify("MicSource device install failed",
                                 install_out[-200:] or "see the activity log",
                                 "dialog-error")
            if self.window and self.window.get_mapped():
                self._refresh()
            return False
        self.log_line(f"build-apk FAILED:\n{short}")
        self._notify("MicSource build failed", short[:200], "dialog-error")
        self._error_dialog("build-apk failed", short)
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
__APPEOF__
    chmod +x "${APP_PATH}"

        cat > "${GUI_PATH}" <<'__GUIEOF__'
#!/usr/bin/env bash
#
# micsource-gui - launch the MicSource control window.
#
# Exec target of the app-drawer launcher. If PyGObject (python3-gi) is not
# installed, shows a desktop notification instead of dying silently.
set -euo pipefail

DATA_DIR="${HOME}/.local/share/micsource"
APP_PATH="${DATA_DIR}/micsource-app.py"

if [[ ! -f "${APP_PATH}" ]]; then
    if command -v notify-send >/dev/null 2>&1; then
        notify-send -i dialog-error "MicSource" \
            "Control window not installed. Run linux-install/install.sh first." \
            >/dev/null 2>&1 || true
    fi
    echo "micsource-gui: ${APP_PATH} not found; run install.sh first." >&2
    exit 1
fi

if python3 -c 'import gi
gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
from gi.repository import Gtk, Adw' >/dev/null 2>&1; then
    if [[ -t 0 ]]; then
        exec python3 "${APP_PATH}"   # terminal: full passthrough
    fi
    # App drawer (no tty): run supervised so a crash can be logged and
    # surfaced as a notification instead of dying silently.
    out="$(python3 "${APP_PATH}" 2>&1)" && exit 0
    printf '%s\n' "${out}" >> "${DATA_DIR}/gui.log"
    if command -v notify-send >/dev/null 2>&1; then
        notify-send -i dialog-error "MicSource" \
            "Control window failed to start. Details in ~/.local/share/micsource/gui.log" \
            >/dev/null 2>&1 || true
    fi
    echo "micsource-gui: window failed to start (logged to ${DATA_DIR}/gui.log):" >&2
    printf '%s\n' "${out}" >&2
    exit 1
fi

msg="PyGObject / GTK 4 / libadwaita is required for the MicSource window. Install it (e.g. 'sudo apt install python3-gi gir1.2-gtk-4.0 gir1.2-adw-1') and relaunch MicSource."
if command -v notify-send >/dev/null 2>&1; then
    notify-send -i dialog-error "MicSource" "${msg}" >/dev/null 2>&1 || true
fi
echo "micsource-gui: ${msg}" >&2
exit 1
__GUIEOF__
    chmod +x "${GUI_PATH}"

        cat > "${TRAY_PATH}" <<'__TRAYEOF__'
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
    # Fall back to the desktop control window instead of dying silently.
    _app = os.path.join(os.path.expanduser("~/.local/share/micsource"),
                        "micsource-app.py")
    print(f"[micsource-tray] tray indicator unavailable ({exc})", flush=True)
    if os.path.isfile(_app):
        print("[micsource-tray] opening the MicSource control window instead",
              flush=True)
        os.execvp("python3", ["python3", _app])  # replace this process
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
__TRAYEOF__
    chmod +x "${TRAY_PATH}"

        cat > "${BUILD_PATH}" <<'__BUILDEOF__'
#!/usr/bin/env bash
#
# micsource-build - build and stage the MicSource APK.
#
# Generated by linux-install/install.sh. Uses the portable JDK 17 / Android
# SDK installed by the installer when present (build-env.path); falls back to
# java on PATH plus local.properties / ANDROID_HOME.
#
# Signs with the release keystore when keystore.properties exists in the
# project root, otherwise with the automatic debug key.
set -euo pipefail

PROJECT_ROOT="/home/hasan/Projects/VIBE/micsource"
DATA_DIR="${HOME}/.local/share/micsource"
ENV_FILE="${DATA_DIR}/build-env.path"
STAGED="${DATA_DIR}/micsource-release.apk"

if [[ -f "${ENV_FILE}" ]]; then
    # build-env.path: JAVA_HOME=... / ANDROID_HOME=... (installer-managed)
    # shellcheck disable=SC1090
    source "${ENV_FILE}"
fi
if [[ -n "${JAVA_HOME:-}" && -x "${JAVA_HOME}/bin/java" ]]; then
    export PATH="${JAVA_HOME}/bin:${PATH}"
fi

if [[ ! -f "${PROJECT_ROOT}/gradlew" ]]; then
    echo "micsource-build: ${PROJECT_ROOT}/gradlew not found (project moved?)." >&2
    exit 1
fi

task="assembleDebug"
if [[ -f "${PROJECT_ROOT}/keystore.properties" ]]; then
    task="assembleRelease"
fi

cd "${PROJECT_ROOT}"
if ! ./gradlew "${task}" --no-daemon; then
    echo "micsource-build: gradle ${task} FAILED." >&2
    exit 1
fi

apk=""
for c in \
    "${PROJECT_ROOT}/app/build/outputs/apk/release/app-release.apk" \
    "${PROJECT_ROOT}/app/build/outputs/apk/release/micsource-release.apk" \
    "${PROJECT_ROOT}/app/build/outputs/apk/debug/app-debug.apk"; do
    if [[ -f "$c" ]]; then apk="$c"; break; fi
done
if [[ -z "$apk" ]]; then
    echo "micsource-build: no APK found under app/build/outputs/apk/." >&2
    exit 1
fi

cp -f "$apk" "${STAGED}"
echo "$apk" > "${DATA_DIR}/apk.path"
echo "micsource-build: built ${apk}"
echo "micsource-build: staged ${STAGED}"
__BUILDEOF__
    chmod +x "${BUILD_PATH}"

    if [[ -L "${BIN_LINK}" ]]; then
        if [[ "$(readlink -f "${BIN_LINK}")" == "$(readlink -f "${CLI_PATH}")" ]]; then
            ok "CLI symlink already in place: ${BIN_LINK}"
        else
            warn "${BIN_LINK} is a symlink pointing elsewhere; leaving it."
        fi
    elif [[ -e "${BIN_LINK}" ]]; then
        warn "${BIN_LINK} exists and is not a MicSource symlink; leaving it."
    else
        ln -s "${CLI_PATH}" "${BIN_LINK}"
        ok "CLI symlink: ${BIN_LINK} -> ${CLI_PATH}"
    fi

    case ":${PATH}:" in
        *:"${HOME}/.local/bin":*) : ;;
        *) warn "${HOME}/.local/bin is not on your PATH."
           info "Add it permanently:  export PATH=\"${HOME}/.local/bin:\$PATH\"" ;;
    esac
    ok "CLI ready.  Try: micsource help"
}

step_tray() {
    if [[ "${WITH_TRAY}" -eq 1 ]]; then
        cat > "${AUTOSTART_FILE}" <<AUTOEOF
[Desktop Entry]
Type=Application
Name=MicSource Tray
Comment=MicSource tray icon (phone microphone over USB)
Exec=${TRAY_PATH}
Icon=micsource
Terminal=false
X-GNOME-Autostart-enabled=true
AUTOEOF
        ok "Tray autostart installed: ${AUTOSTART_FILE}"
    else
        info "Tray is opt-in: enable it from the control window's Preferences."
    fi
    if ! python3 -c 'import gi
gi.require_version("Gtk", "3.0")
gi.require_version("AppIndicator3", "0.1")' >/dev/null 2>&1; then
        warn "The AppIndicator/Ayatana Python binding is not installed; the tray"
        info "will fall back to opening the control window. Install it, e.g."
        info "  sudo apt install gir1.2-appindicator3-0.1"
        info "On GNOME (without appindicator), use the quick settings pill instead."
    fi
}

step_systemd() {
        cat > "${MON_PATH}" <<'__MONITOREOF__'
#!/usr/bin/env python3
"""
MicSource systemd user service.

Background monitoring / detection / config for the MicSource host side.
Runs as the user (no root). Responsibilities:
  * Keep the adb socket forward active (re-establish if dropped).
  * Start the device app when it comes online (rate limited).
  * Forward received PCM audio (16-bit mono 44.1 kHz) to paplay/aplay.
  * Expose a control Unix socket for status queries and restarts.
"""
import array
import configparser
import math
import os
import re
import socket
import subprocess
import sys
import threading
import time

DATA_DIR = os.path.expanduser("~/.local/share/micsource")
CONFIG_DIR = os.path.expanduser("~/.config/micsource")
CONFIG_PATH = os.path.join(CONFIG_DIR, "config.ini")
ADB_PATH_FILE = os.path.join(DATA_DIR, "adb.path")
CONTROL_SOCKET = os.path.join(DATA_DIR, "micsource.sock")

ANDROID_PKG = "fr.dzx.audiosource"  # Android package (baked into the APK)
DEVICE_SOCKET = "audiosource"       # Device-side socket (RecordThread)
DEFAULT_HOST_SOCKET = "micsource"   # Host side of the adb forward

running = True
audio_procs = []
audio_lock = threading.Lock()

# Live input level (metering): RMS of the pumped PCM, smoothed with a fast
# attack / slow release and exposed over the control socket (`level`).
_audio_level = 0.0     # smoothed 0..1 (dBFS mapped: -60..-15 dB -> 0..1)
_level_update = 0.0    # time.time() of the last sample-consuming update
_level_lock = threading.Lock()

ADB_CMD = "adb"
SERIAL = None

# Device name lookup cache
STATE = {"device_name": {}, "device_name_serial": {}}
HOST_SOCKET = DEFAULT_HOST_SOCKET


def _log(msg):
    print(f"[micsource-monitor] {msg}", flush=True)


def device_name():
    """Device model lookup via adb -- supports uppercase/lowercase getprop."""
    global SERIAL

    serial = SERIAL or ""
    cached = STATE["device_name"].get(serial)
    if cached:
        return str(cached)
    # reset cache entry when a NEW serial is seen (handles replug)
    if serial != STATE["device_name_serial"].get("active"):
        STATE["device_name"] = {}
        STATE["device_name_serial"]["active"] = serial

    value = ""
    for prop in ("ro.product.marketname", "ro.product.model",
                 "ro.product.vendor.model", "ro.product.brand"):
        _rc, out, _err = run_adb(
            ["shell", "getprop", str(prop)], timeout=6)
        value = str(out).strip()
        if value:
            break
    if value:
        STATE["device_name"][serial] = value
    return value


def _load_config():
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


def run_adb(args, timeout=6):
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
    rc, out, _err = run_adb(["get-state"], timeout=4)
    return rc == 0 and out.strip() == "device"


def socket_forwarded():
    rc, out, _err = run_adb(["forward", "--list"], timeout=4)
    return rc == 0 and (f"localabstract:{HOST_SOCKET}" in out)


def ensure_forward():
    """(Re)establish the host/socket forward. Returns (ok, stderr)."""
    run_adb(["forward", "--remove", f"localabstract:{HOST_SOCKET}"], timeout=4)
    rc, _out, err = run_adb(
        ["forward", f"localabstract:{HOST_SOCKET}", f"localabstract:{DEVICE_SOCKET}"],
        timeout=6,
    )
    return rc == 0, err


def start_device_service():
    run_adb(["shell", "am", "force-stop", ANDROID_PKG], timeout=8)
    rc, _out, err = run_adb(
        ["shell", "am", "start", f"{ANDROID_PKG}/.MainActivity"], timeout=10
    )
    return rc == 0, err


# --------------------------------------------------------------------------
# Virtual microphone (null-sink + remap-source).
#
# While monitoring, the PCM stream from the phone is played into a null-sink
# ("phone-out") whose monitor source is remapped into a virtual input source
# named "phone-mic" ("MicSource-phone-mic" in application pickers), so apps
# (browsers, VOIP, recorders, ...) can use the phone mic as a normal input
# device. PipeWire's compat layer does not implement module-pipe-source's
# data path, hence this design. Speaker playback is controlled by
# [audio] play_to_speakers (default true).
# --------------------------------------------------------------------------
VMIC_NAME = "phone-mic"
_sink_mod = None
_src_mod = None
_vmic_lock = threading.Lock()
_vm_ok = False
_pumping = False
_pcm_bytes = 0
audio_procs = []


def _cfg_bool(section, key, default):
    parser = configparser.ConfigParser()
    try:
        parser.read(CONFIG_PATH)
        val = parser.get(section, key, fallback="").strip().lower()
        return default if not val else val not in ("0", "no", "false", "off")
    except Exception:
        return default


def _speakers_enabled():
    return _cfg_bool("audio", "play_to_speakers", False)


def _vmic_enabled():
    return _cfg_bool("audio", "virtual_mic", True)


def _vmic_running():
    # Is a source named VMIC_NAME already registered in the audio server?
    try:
        res = subprocess.run(["pactl", "list", "sources", "short"],
                             capture_output=True, text=True, timeout=5)
        for line in (res.stdout or "").splitlines():
            parts = line.split()
            if len(parts) >= 2 and parts[1] == VMIC_NAME:
                return True
    except Exception:
        pass
    return False


def _vmic_cleanup_leftovers():
    """Unload phone-out / phone-mic modules left by other runs, so this
    instance owns (and can later unload) the whole chain."""
    groups = []
    for kind, names in (("sinks", ("phone-out",)), ("sources", (VMIC_NAME,))):
        try:
            res = subprocess.run(["pactl", "list", kind],
                                 capture_output=True, text=True, timeout=5)
        except Exception:
            continue
        owned = None
        for line in (res.stdout or "").splitlines():
            text = line.strip()
            if text.startswith("Name:") and text.split(":", 1)[1].strip() in names:
                owned = True
            elif owned and text.startswith("Owner Module:"):
                idx = text.split(":", 1)[1].strip()
                if idx.isdigit() and idx not in groups:
                    groups.append(idx)
                owned = None
    for idx in groups:
        try:
            subprocess.run(["pactl", "unload-module", idx],
                           capture_output=True, timeout=5)
        except Exception:
            pass
    return len(groups)


def _phone_out_exists():
    try:
        res = subprocess.run(["pactl", "list", "sinks", "short"],
                             capture_output=True, text=True, timeout=5)
        for line in (res.stdout or "").splitlines():
            parts = line.split()
            if len(parts) >= 2 and parts[1] == "phone-out":
                return True
    except Exception:
        pass
    return False


def _vmic_start():
    """Create the phone-mic input source (null-sink + remap-source).

    PipeWire's PulseAudio compat layer does not implement the data path of
    module-pipe-source (it registers a silent source), so the classic FIFO
    approach stays silent on PipeWire systems. Instead the phone stream is
    played into a null-sink whose monitor is remapped into a real input
    source named phone-mic. Never raises."""
    global _sink_mod, _src_mod, _vm_ok
    with _vmic_lock:
        if _vm_ok or not _vmic_enabled():
            return
        if _phone_out_exists():
            stale = _vmic_cleanup_leftovers()
            if stale == 0:
                _sink_mod = _src_mod = None  # created by another live instance
                _vm_ok = True
                return
            _log(f"recreating leftover phone-* audio modules ({stale})")
        try:
            res = subprocess.run(
                ["pactl", "load-module", "module-null-sink",
                 "sink_name=phone-out",
                 "sink_properties=device.description=MicSource-phone-sink"],
                capture_output=True, text=True, timeout=10)
        except FileNotFoundError:
            _log("virtual mic unavailable: pactl not found")
            return
        except Exception as exc:
            _log(f"virtual mic null-sink failed: {exc}")
            return
        if res.returncode != 0:
            _log("virtual mic sink unavailable: "
                 + ((res.stderr or res.stdout or "").strip()[:120]
                    or "module-null-sink failed"))
            return
        _sink_mod = (res.stdout or "").strip() or None
        try:
            res = subprocess.run(
                ["pactl", "load-module", "module-remap-source",
                 "master=phone-out.monitor",
                 f"source_name={VMIC_NAME}",
                 "source_properties=device.description=MicSource-phone-mic",
                 "channels=1", "master_channel_map=mono", "channel_map=mono",
                 "remap=mono"],
                capture_output=True, text=True, timeout=10)
        except Exception as exc:
            _log(f"virtual mic remap-source failed: {exc}")
            return
        if res.returncode != 0:
            _log("virtual mic remap failed; apps can use "
                 "'Monitor of MicSource-phone-sink' as input")
            return
        _src_mod = (res.stdout or "").strip() or None
        _vm_ok = True
        _log(f"virtual microphone source '{VMIC_NAME}' ready")


def _vmic_stop():
    global _sink_mod, _src_mod, _vm_ok
    with _vmic_lock:
        _vm_ok = False
        for idx in (_src_mod, _sink_mod):
            if idx is not None:
                try:
                    subprocess.run(["pactl", "unload-module", str(idx)],
                                   capture_output=True, timeout=5)
                except Exception:
                    pass
        _src_mod = _sink_mod = None


def _set_stdin_nonblocking(child):
    if child is None or child.stdin is None:
        return
    try:
        import fcntl
        fd = child.stdin.fileno()
        flags = fcntl.fcntl(fd, fcntl.F_GETFL)
        fcntl.fcntl(fd, fcntl.F_SETFL, flags | os.O_NONBLOCK)
    except Exception:
        pass


# Env props for the players: a distinctive media.role identifies MicSource
# streams, and the node.* properties ask WirePlumber/PipeWire never to
# re-route or fall back. Without them PipeWire (observed on 1.6.8) moves the
# --device=phone-out stream onto the desktop's default speakers via
# stream-restore/WirePlumber policy, leaving phone-mic silent and leaking
# the phone audio to the physical speakers.
_PLAYER_ENV = dict(os.environ)
_PLAYER_ENV["PULSE_PROP"] = ("media.role=MicSource "
                             "node.dont-move=true "
                             "node.dont-fallback=true")


def _spawn_player(args_extra=None):
    """Spawn one paplay consuming raw PCM on stdin; args_extra may target a
    sink (e.g. --device=phone-out for the virtual-mic chain)."""
    argv = ["paplay", "--raw", "--format=s16le", "--rate=44100", "--channels=1",
            "--latency=200"]
    if args_extra:
        argv.extend(args_extra)
    child = None
    try:
        child = subprocess.Popen(
            argv,
            stdin=subprocess.PIPE,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            env=_PLAYER_ENV,
        )
    except (FileNotFoundError, OSError):
        return None
    _set_stdin_nonblocking(child)
    return child


def start_audio():
    """Start forwarding device PCM audio (speakers and/or virtual mic)."""
    global _pumping
    with audio_lock:
        if _pumping:
            _vmic_start()
            return True
        kids = []
        if _vmic_enabled():
            _vmic_start()
            if _vm_ok:
                kid = _spawn_player(args_extra=["--device=phone-out"])
                if kid is None:
                    _log("warning: no paplay found; phone-mic will be silent")
                else:
                    kids.append(kid)
        if _speakers_enabled():
            kid = _spawn_player()
            if kid is None:
                _log("no paplay found; speaker playback skipped")
            else:
                kids.append(kid)
        if not kids:
            _log("no audio output enabled: set play_to_speakers or virtual_mic in config")
            return False
        audio_procs[:] = kids
        _pumping = True
    threading.Thread(target=_pump, daemon=True).start()
    return True


def stop_audio():
    global _pumping
    with audio_lock:
        _pumping = False
    _vmic_stop()
    for child in audio_procs:
        try:
            child.stdin.close()
        except Exception:
            pass
        try:
            child.terminate()
            child.wait(timeout=3)
        except Exception:
            try:
                child.kill()
            except Exception:
                pass
    audio_procs.clear()


def _route_guard():
    """Repair players that the audio policy re-routed off their target.

    WirePlumber / module-stream-restore has been observed moving our
    paplay stream onto the desktop's default output despite
    --device=phone-out, which leaves phone-mic silent and leaks the phone
    audio to the real speakers. Detect a mis-routed child (matched by PID
    to its sink-input) and restore the intended routing.
    """
    try:
        outs = subprocess.run(["pactl", "list", "sinks", "short"],
                              capture_output=True, text=True, timeout=3).stdout
        phone_idx = None
        for line in outs.splitlines():
            parts = line.split("\t")
            if len(parts) >= 2 and parts[1] == "phone-out":
                phone_idx = int(parts[0])
                break
        if phone_idx is None:
            return  # virtual mic not loaded; nothing to guard
        ins = subprocess.run(["pactl", "list", "sink-inputs"],
                             capture_output=True, text=True, timeout=3).stdout
        owner = {}  # client pid -> (sink_input_index, sink_index)
        blocks = re.findall(r"Sink Input #(\d+)\n(.*?)(?=\nSink Input #\d+\n|\Z)",
                            ins, re.S)
        for sid, body in blocks:
            m_sink = re.search(r"^\s*Sink:\s*(\d+)", body, re.M)
            m_pid = re.search(r'application\.process\.id\s*=\s*"?\d+', body)
            if m_sink and m_pid:
                owner.setdefault(int(re.search(r"\d+", m_pid.group(0)).group()),
                                 (int(sid), int(m_sink.group(1))))
        with audio_lock:
            kids = list(audio_procs)
        for child in kids:
            if child.poll() is not None:
                continue
            entry = owner.get(child.pid)
            if entry is not None and entry[1] != phone_idx:
                _log(f"player {child.pid} was re-routed to sink "
                     f"{entry[1]} (expected {phone_idx}); repairing")
                subprocess.run(["pactl", "move-sink-input", str(entry[0]),
                                str(phone_idx)],
                               capture_output=True, timeout=3)
    except Exception as exc:
        _log(f"route guard skipped: {exc}")


def _update_level(data):
    """Fold one s16le mono PCM chunk into the smoothed input level.

    Mapping: dBFS -60..-15 -> 0..1 so that (typical) close-mic speech sits
    clearly above room noise; display only, not for gain.
    """
    global _audio_level, _level_update
    try:
        samples = array.array("h")
        samples.frombytes(data[:len(data) // 2 * 2])
        if not samples:
            return
        rms = math.sqrt(sum(v * v for v in samples) / len(samples)) / 32768.0
        db = 20 * math.log10(rms) if rms > 0 else -90.0
        lvl = max(0.0, min(1.0, (db + 60.0) / 45.0))
        now = time.time()
        with _level_lock:
            prev = _audio_level
            coef = 0.45 if lvl >= prev else 0.15  # fast attack, slow release
            _audio_level = prev + (lvl - prev) * coef
            _level_update = now
    except Exception:
        pass


def _current_level():
    """Smoothed level with idle decay (used by the control socket)."""
    with _level_lock:
        lvl, upd = _audio_level, _level_update
    age = time.time() - upd
    if age > 0.5:
        lvl *= max(0.0, 1.0 - (age - 0.5))
    return max(0.0, min(1.0, lvl))


def _pump():
    """Read PCM from the host-side forward socket and pipe it to the player."""
    global _pcm_bytes
    while True:
        with audio_lock:
            pumping = _pumping
        if not pumping:
            break
        sock = None
        try:
            sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            sock.settimeout(5)
            sock.connect(b"\0" + HOST_SOCKET.encode())
            while True:
                with audio_lock:
                    children = [c for c in audio_procs if c.poll() is None]
                    pumping = _pumping
                if not pumping:
                    break
                try:
                    data = sock.recv(4096)
                except (socket.timeout, OSError):
                    break
                if not data:
                    break
                _pcm_bytes += len(data)
                _update_level(data)
                for child in children:
                    try:
                        child.stdin.write(data)
                        child.stdin.flush()
                    except (BrokenPipeError, OSError):
                        pass
        except OSError:
            pass
        finally:
            if sock is not None:
                try:
                    sock.close()
                except OSError:
                    pass
        time.sleep(2)


def control_server():
    """Control Unix socket: status queries and restarts (single instance)."""
    try:
        if os.path.exists(CONTROL_SOCKET):
            os.unlink(CONTROL_SOCKET)
        srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        srv.bind(CONTROL_SOCKET)
        os.chmod(CONTROL_SOCKET, 0o600)
        srv.listen(4)
    except OSError as exc:
        _log(f"control socket unavailable: {exc}")
        return
    try:
        while running:
            try:
                srv.settimeout(1.0)
                conn, _addr = srv.accept()
            except socket.timeout:
                continue
            except OSError:
                break
            try:
                conn.settimeout(2.0)
                data = conn.recv(64)
                cmd = data.decode(errors="ignore").strip()
                if cmd == "status":
                    onl = device_online()
                    fwd = socket_forwarded()
                    resp = (f"device={int(onl)} forward={int(fwd)} "
                            f"audio_seconds={_pcm_bytes // 88200}")
                    name = device_name() if onl else ""
                    if name:
                        resp += f" name={name}"
                elif cmd == "level":
                    resp = f"{_current_level():.3f}"
                elif cmd == "restart":
                    stop_audio()
                    ensure_forward()
                    start_audio()
                    resp = "restarted"
                else:
                    resp = "unknown"
                conn.sendall(resp.encode())
            except Exception:
                pass
            finally:
                try:
                    conn.close()
                except Exception:
                    pass
    finally:
        try:
            srv.close()
        except Exception:
            pass
        try:
            if os.path.exists(CONTROL_SOCKET):
                os.unlink(CONTROL_SOCKET)
        except OSError:
            pass


def _desktop_notify(body):
    """Best-effort desktop notification via notify-send."""
    try:
        subprocess.run(
            ["notify-send", "-i", "audio-input-microphone", "MicSource", body],
            capture_output=True, timeout=5,
        )
    except Exception:
        pass


_prev_state = None


def _notify_transition(state):
    """Send a desktop notification when the (online, forwarded) state changes."""
    global _prev_state
    if _prev_state is not None and state != _prev_state:
        online, forwarded = state
        if online and forwarded:
            _desktop_notify("Device connected — forwarding audio.")
        elif online:
            _desktop_notify("Device connected — waiting for forwarding.")
        else:
            _desktop_notify("Device disconnected.")
    _prev_state = state


def main_loop():
    _log("MicSource monitor starting")
    offline_ticks = 0
    last_bytes = 0
    stall_ticks = 0
    while running:
        try:
            online = device_online()
            forwarded = socket_forwarded() if online else False
            if online:
                offline_ticks = 0
                if not forwarded:
                    ensure_forward()
                    forwarded = socket_forwarded()
                start_audio()
                _route_guard()
                # If the forward is live but no audio arrives for ~20 s, the
                # phone app is wedged (e.g. after an APK replacement):
                # relaunch it so the recorder starts again.
                now_bytes = _pcm_bytes
                if forwarded and now_bytes == last_bytes:
                    stall_ticks += 1
                    if stall_ticks >= 4:
                        stall_ticks = 0
                        _log("no audio flowing; restarting the phone app")
                        start_device_service()
                else:
                    stall_ticks = 0
                last_bytes = now_bytes
            else:
                stop_audio()
                offline_ticks += 1
                # Try to launch the app on device at most once per ~30 s.
                if offline_ticks >= 6:
                    offline_ticks = 0
                    start_device_service()
            _notify_transition((online, forwarded))
        except Exception as exc:
            _log(f"loop error: {exc}")
        time.sleep(5)


def _run_once():
    """Foreground mode (--run): set up the forward, stream until Ctrl+C."""
    _load_config()
    ok, err = ensure_forward()
    if not ok:
        _log(f"could not set up socket forward: {err}")
        return 1
    if not start_audio():
        _log("no audio player found; cannot stream audio")
        return 1
    _log("forwarding until Ctrl+C…")
    try:
        while True:
            with audio_lock:
                procs = list(audio_procs)
                pumping = _pumping
            if not pumping:
                break
            if procs and all(c.poll() is not None for c in procs):
                _log("players exited; stopping")
                break
            time.sleep(1)
    except KeyboardInterrupt:
        pass
    stop_audio()
    _log("stopped")
    return 0


def main():
    global running
    # Make SIGTERM (systemctl stop, `micsource stop`) graceful so the
    # virtual mic modules are unloaded on shutdown.
    import signal

    def _catch(_sig, _frame):
        global running
        running = False

    signal.signal(signal.SIGTERM, _catch)
    signal.signal(signal.SIGINT, _catch)
    threading.Thread(target=control_server, daemon=True).start()
    _load_config()
    try:
        main_loop()
    except KeyboardInterrupt:
        running = False
    stop_audio()
    _log("MicSource monitor stopped")


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--run":
        raise SystemExit(_run_once())
    main()
__MONITOREOF__
    chmod +x "${MON_PATH}"

    cat > "${UNIT_FILE}" <<UNITEOF
[Unit]
Description=MicSource host monitor (adb socket forward + audio playback)
After=graphical-session.target
Wants=graphical-session.target

[Service]
Type=simple
ExecStart="${MON_PATH}"
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
    mkdir -p "${GNOME_EXT_DIR}"
        cat > ""${GNOME_EXT_DIR}/extension.js"" <<'__EXTJSEOF__'
// MicSource quick-settings pill (GNOME Shell 45+ ES module).
// Default-export Extension subclass: GNOME Shell loads extensions by
// instantiating the module's default export (function-form enable/disable
// raises 'extensionModule.default is not a constructor' on modern Shell).
//
// Design (GNOME Quick Settings / GSConnect pattern):
//   * pill = QuickSettings.QuickMenuToggle with a live status subtitle
//   * pill click = start/stop the background service
//   * pill chevron = expandable menu with Device + Monitoring status
//     rows (same information as the control window) and actions.
// Status is polled through the micsource CLI (async subprocess, no adb
// socket poking from the shell main loop).
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import GObject from 'gi://GObject';
import { Extension } from 'resource:///org/gnome/shell/extensions/extension.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as PopupMenu from 'resource:///org/gnome/shell/ui/popupMenu.js';
import * as QuickSettings from 'resource:///org/gnome/shell/ui/quickSettings.js';

const SERVICE = 'micsource.service';

const MicSourceToggle = GObject.registerClass({
    GTypeName: 'MicSourceToggle',
}, class MicSourceToggle extends QuickSettings.QuickMenuToggle {
    _init(ext) {
        this._ext = ext;            // stored before super._init
        super._init({
            title: 'MicSource',
            subtitle: 'checking…',
            // Plain mic icon in both states: the -muted variant carries an
            // x-badge that visually misaligns the pill icon. State is
            // conveyed by the subtitle text and the checked accent colour.
            iconName: 'audio-input-microphone-symbolic',
            // checked is driven by apply() from the real service state, so
            // a failed click can never briefly lie (accent flicker).
            toggleMode: false,
        });

        // Expanded menu: same two status lines as the control window,
        // then the same actions (HIG: quick settings menu = header +
        // rows + actions).
        this.menu.setHeader('audio-input-microphone-symbolic',
            'MicSource', 'phone mic over USB');

        this._deviceItem = new PopupMenu.PopupMenuItem('Device: —',
            { reactive: false });
        this._monItem = new PopupMenu.PopupMenuItem('Monitoring: —',
            { reactive: false });
        this.menu.addMenuItem(this._deviceItem);
        this.menu.addMenuItem(this._monItem);
        this.menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem());

        this._svcItem = new PopupMenu.PopupMenuItem('Start Service');
        this._svcItem.connect('activate', () => this._toggleService());
        this.menu.addMenuItem(this._svcItem);

        const winItem = new PopupMenu.PopupMenuItem('Open Control Window');
        winItem.connect('activate', () => this._openWindow());
        this.menu.addMenuItem(winItem);

        // Some shell point releases / themes indent the quick-toggle
        // subtitle; pin it to the left edge to match the title. The
        // subtitle label lives on the *inner* QuickToggle (since GNOME 45
        // QuickMenuToggle wraps one instead of subclassing it, so there
        // is no this._subtitle on ourselves — the direct access crashed
        // _init on GNOME 51). Climb the one level of widgets the shell
        // owns; optional chaining keeps _init safe even if the shell
        // re-lays out its internals again.
        const innerToggle = this._box?.get_first_child();
        this._subtitle = innerToggle?._subtitle ?? null;
        this._subtitle?.set_style('text-align: left; padding-left: 0;');

        this._monitoring = false;   // monitor answered "status"
        this._device = false;       // phone link seen
        this._svc = null;           // systemd unit state (may be null)
        this._ext = ext;            // exposes the fast re-poll

        // Clicking the pill toggles the service; the chevron opens the
        // menu. A fast re-poll grounds `checked` in the real state.
        this.connect('clicked', () => this._toggleService());
    }

    _refreshSoon() {
        if (this._ext && this._ext._refreshNext) {
            this._ext._refreshNext();
        }
    }

    // Called by the extension with a parsed CLI `status` output.
    apply(svc, device, monitoring, name) {
        this._svc = svc;
        this._device = device;
        this._monitoring = monitoring;
        this._name = name || '';

        const svcActive = svc === 'active';
        // Pill state + look (audio muted icon mirrors the app's Start
        // button sensitivity: service running = mic available).
        // checked gives the pill the active accent colour while the
        // monitoring/service is running (GNOME .quick-toggle:checked style)
        this.checked = monitoring || svcActive;

        // Title spec:
        //   off                    -> "Service — off"
        //   on + connected phone   -> device model name
        //   on + no phone          -> "Disconnected"
        //   service coming up      -> "starting…"
        if (!monitoring && !svcActive)
            this.subtitle = 'Service — off';
        else if (monitoring && device)
            this.subtitle = this._name || 'on · phone connected';
        else if (monitoring)
            this.subtitle = 'Disconnected';
        else
            this.subtitle = 'starting…';

        // Menu rows (mirror the control window's status rows).
        if (this._deviceItem.label)
            this._deviceItem.label.text =
                'Device: ' + (device
                    ? (this._name || 'connected') : 'disconnected');
        if (this._monItem.label)
            this._monItem.label.text =
                'Monitoring: ' + (monitoring
                    ? (device
                        ? ('on — streaming' +
                           (this._name ? ' · ' + this._name : ''))
                        : 'on — waiting')
                    : (svcActive ? 'starting…' : 'off'));
        if (this._svcItem.label)
            this._svcItem.label.text = svcActive
                ? 'Stop Service' : 'Start Service';
    }

    _toggleService() {
        try {
            const active = this._monitoring || this._svc === 'active';
            const verb = active ? 'stop' : 'start';
            const cli = GLib.build_filenamev([GLib.get_home_dir(),
                '.local', 'share', 'micsource', 'micsource']);
            log('MicSource: pill click -> service ' + verb);
            Gio.Subprocess.new([cli, verb], Gio.SubprocessFlags.NONE);
        } catch (e) {
            console.error(`MicSource: toggle failed: ${e}`);
        }
        // ~1 s re-poll grounds the pill in the real service state
        this._refreshSoon();
    }

    _openWindow() {
        const cli = GLib.build_filenamev([GLib.get_home_dir(),
            '.local', 'share', 'micsource', 'micsource']);
        try {
            Gio.Subprocess.new([cli, 'window'], Gio.SubprocessFlags.NONE);
        } catch (e) {
            console.error(`MicSource: open window failed: ${e}`);
        }
    }

    destroy() {
        super.destroy();
    }
});

export default class MicSourceExtension extends Extension {
    enable() {
        this._cancellable = new Gio.Cancellable();

        this._toggle = new MicSourceToggle(this);
        const indicator = new QuickSettings.SystemIndicator();
        indicator.quickSettingsItems.push(this._toggle);
        this._indicator = indicator;
        // External indicators (pill-only, no top-bar icon) are registered
        // through quickSettings on every shell this API exists on;
        // Main.panel.addToStatusArea() would throw "Status indicator must
        // be an instance of PanelMenu.Button".
        Main.panel.statusArea.quickSettings.addExternalIndicator(
            this._indicator);

        this._timer = GLib.timeout_add_seconds(GLib.PRIORITY_DEFAULT, 4,
            () => {
                this._refresh();
                return GLib.SOURCE_CONTINUE;
            });
        this._refresh();
    }

    // fast, deduplicated re-poll after a user action (pill click etc.)
    _refreshNext() {
        if (this._soon) {
            GLib.source_remove(this._soon);
        }
        this._soon = GLib.timeout_add(GLib.PRIORITY_DEFAULT, 1200, () => {
            this._soon = null;
            this._refresh();
            return GLib.SOURCE_REMOVE;
        });
    }

    _spawnGet(argv, callback) {
        try {
            const proc = Gio.Subprocess.new(argv,
                Gio.SubprocessFlags.STDOUT_PIPE |
                Gio.SubprocessFlags.STDERR_PIPE);
            proc.communicate_utf8_async(null, this._cancellable,
            (procObj, res) => {
                if (!this._cancellable || this._cancellable.is_cancelled())
                    return;
                try {
                    const [, out, err] =
                        procObj.communicate_utf8_finish(res);
                    callback((out || '') + (err || ''));
                } catch (e) {
                    callback('');
                }
            });
        } catch (e) {
            console.error(`MicSource: spawn failed: ${e}`);
            callback('');
        }
    }

    _refresh() {
        const cli = GLib.build_filenamev([GLib.get_home_dir(),
            '.local', 'share', 'micsource', 'micsource']);
        this._spawnGet([cli, 'status'], (out) => {
            let svc = null;
            let device = false;
            let monitoring = false;

            const m = out.match(/monitor:\s*device=(\d+)\s+forward=/);
            if (m) { monitoring = true; device = m[1] === '1'; }

            const s = out.match(/systemd unit:\s*([A-Za-z-]+)/);
            if (s) svc = s[1];

            const d = out.match(/adb device state:\s*([A-Za-z]+)/);
            if (d) device = device || d[1].toLowerCase() === 'device';

            // Device model reported by the monitor (name=Pixel 8).
            const nm = out.match(/monitor:[^\n]*\bname=([^\n\r]+)/);
            const name = nm ? nm[1].trim() : '';

            if (this._toggle && !this._cancellable.is_cancelled()) {
                this._toggle.apply(svc, device, monitoring, name);
            }
        });
    }

    disable() {
        if (this._cancellable) {
            this._cancellable.cancel();
            this._cancellable = null;
        }
        if (this._timer) {
            GLib.source_remove(this._timer);
            this._timer = null;
        }
        if (this._soon) {
            GLib.source_remove(this._soon);
            this._soon = null;
        }
        if (this._toggle) {
            this._toggle.destroy();
            this._toggle = null;
        }
        if (this._indicator) {
            this._indicator.destroy();
            this._indicator = null;
        }
    }
}
__EXTJSEOF__
        cat > ""${GNOME_EXT_DIR}/prefs.js"" <<'__PREFSEOF__'
// MicSource extension preferences (no options for now; GNOME 45+ API).
import Adw from 'gi://Adw';
import { ExtensionPreferences } from 'resource:///org/gnome/Shell/Extensions/js/extensions/prefs.js';

export default class MicSourcePrefs extends ExtensionPreferences {
    fillPreferencesWindow(window) {
        const page = new Adw.PreferencesPage();
        const group = new Adw.PreferencesGroup({ title: 'MicSource' });
        const row = new Adw.ActionRow({
            title: 'No preferences yet',
            subtitle: 'Edit ~/.config/micsource/config.ini instead',
        });
        group.add(row);
        page.add(group);
        window.add(page);
    }
}
__PREFSEOF__
        cat > ""${GNOME_EXT_DIR}/metadata.json"" <<'__METADATAEOF__'
{"uuid": "micsource-tile@micsource.local", "name": "MicSource Quick Settings Pill", "description": "MicSource status pill and expandable menu in the Quick Settings grid", "version": 6, "shell-version": ["47", "48", "49", "50", "51"], "__metaVersion__": 6}
__METADATAEOF__
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
    cat > "${PULSE_LOCK_CONF}" <<LOCKEOF
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
    step_sanity
    step_adb             || true
    step_build_env       || true
    step_apk             || true
    step_device          || true
    step_config          || true
    step_desktop         || true
    step_cli             || true
    step_tray            || true
    step_systemd         || true
    step_gnome_extension || true
    step_pipewire        || true
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
