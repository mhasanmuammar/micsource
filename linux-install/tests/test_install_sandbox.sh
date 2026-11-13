#!/usr/bin/env bash
#
# test_install_sandbox.sh - Sandboxed install/uninstall tests for MicSource
#
# Drives linux-install/install.sh and linux-install/uninstall.sh against a
# synthetic fixture (or a real install) under a fake $HOME beneath
# /tmp/opencode/, with logging stubs for adb / systemctl / gnome-extensions
# placed ahead of the real commands on PATH. Every invocation gets HOME,
# PATH and XDG_CURRENT_DESKTOP explicitly via env, so the live user session,
# real services, and any connected Android device are never touched.
#
# Usage: bash linux-install/tests/test_install_sandbox.sh
# Output: one PASS/FAIL line per case; exits 0 iff every case passes.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
INSTALL="${REPO_ROOT}/linux-install/install.sh"
UNINSTALL="${REPO_ROOT}/linux-install/uninstall.sh"
RUNTIME_ROOT="/tmp/opencode"

PASSED=0
FAILED=0

CURRENT_CASE=""
CASE_TITLE=""
CASE_ERRORS=()

SANDBOX=""
SANDBOX_HOME=""
STUBBIN=""
STUB_LOG=""
TEST_STDOUT=""
TEST_STDERR=""
COMBINED=""
TEST_XDG_DESKTOP=""
RC=0

SAVED_SANDBOX=""
SAVED_SANDBOX_HOME=""
SAVED_STUB_LOG=""
SAVED_TEST_STDOUT=""
SAVED_TEST_STDERR=""
SAVED_COMBINED=""
SAVED_TEST_XDG_DESKTOP=""

SANDBOXES=()

##############################################################################
# Harness: case bookkeeping (one PASS/FAIL line per case)
##############################################################################
start_case() { # start_case <id> <title>
    CURRENT_CASE="$1"
    CASE_TITLE="$2"
    CASE_ERRORS=()
}

fail_case() {
    CASE_ERRORS+=("[${CURRENT_CASE}] $*")
}

end_case() {
    local line
    if ((${#CASE_ERRORS[@]} == 0)); then
        printf 'PASS: %s\n' "${CASE_TITLE}"
        PASSED=$((PASSED + 1))
    else
        printf 'FAIL: %s\n' "${CASE_TITLE}"
        for line in "${CASE_ERRORS[@]}"; do
            printf '      %s\n' "${line}"
        done
        FAILED=$((FAILED + 1))
    fi
}

##############################################################################
# Harness: assertions
##############################################################################
assert_file() {
    [[ -e "$1" || -L "$1" ]] || fail_case "expected to exist: $1"
}

assert_gone() {
    [[ -e "$1" || -L "$1" ]] && fail_case "expected to be gone: $1"
    return 0
}

assert_contains() { # assert_contains <file> <text>   (fixed-string)
    grep -Fq -- "$2" "$1" || fail_case "($1) missing expected text: $2"
}

assert_not_contains() { # assert_not_contains <file> <text>   (fixed-string)
    grep -Fq -- "$2" "$1" && fail_case "($1) contains unexpected text: $2"
    return 0
}

assert_matches() { # assert_matches <file> <extended-regex>
    grep -Eq -- "$2" "$1" || fail_case "($1) does not match: $2"
}

assert_no_esc() { # assert_no_esc <file>   (no ANSI escape byte in the output)
    LC_ALL=C grep -q "$(printf '\033')" "$1" &&
        fail_case "($1) contains ESC bytes (colors must be empty for non-TTY output)"
    return 0
}

assert_exit() { # assert_exit <expected> <actual>
    [[ "$1" == "$2" ]] || fail_case "exit status: expected $1, got $2"
}

##############################################################################
# Harness: sandbox + logging stubs
##############################################################################
# Derive every TEST_* path from SANDBOX/SANDBOX_HOME. make_sandbox and
# restore_sandbox both call this so a restored sandbox always asserts against
# its own paths (restoring only SANDBOX/HOME used to leave the previous
# sandbox's TEST_* values behind, which made the round-trip case vacuous).
derive_test_paths() {
    TEST_DATA_DIR="${SANDBOX_HOME}/.local/share/micsource"
    TEST_CONFIG_DIR="${SANDBOX_HOME}/.config/micsource"
    TEST_APPS_DIR="${SANDBOX_HOME}/.local/share/applications"
    TEST_SYSTEMD_DIR="${SANDBOX_HOME}/.config/systemd/user"
    TEST_ICON_DIR="${SANDBOX_HOME}/.local/share/icons/hicolor/scalable/apps"
    TEST_BIN_DIR="${SANDBOX_HOME}/.local/bin"
    TEST_EXT_DIR="${SANDBOX_HOME}/.local/share/gnome-shell/extensions/micsource-tile@micsource.local"
    TEST_AUTOSTART_DIR="${SANDBOX_HOME}/.config/autostart"
    TEST_PIPEWIRE_DIR="${SANDBOX_HOME}/.config/pipewire/pipewire-pulse.conf.d"

    TEST_UNIT="${TEST_SYSTEMD_DIR}/micsource.service"
    TEST_DESKTOP="${TEST_APPS_DIR}/micsource.desktop"
    TEST_ICON="${TEST_ICON_DIR}/micsource.svg"
    TEST_CLI_LINK="${TEST_BIN_DIR}/micsource"
    TEST_ADB_LINK="${TEST_BIN_DIR}/adb"
    TEST_AUTOSTART="${TEST_AUTOSTART_DIR}/micsource-tray.desktop"
    TEST_PULSE_LOCK="${TEST_PIPEWIRE_DIR}/10-micsource-stream-lock.conf"
    TEST_EXT_METADATA="${TEST_EXT_DIR}/metadata.json"
    TEST_SOCK="${TEST_DATA_DIR}/micsource.sock"
    TEST_CONFIG_INI="${TEST_CONFIG_DIR}/config.ini"
    TEST_ADB_BUNDLE_DIR="${TEST_DATA_DIR}/adb-bundle"
    TEST_ADB_BUNDLE="${TEST_ADB_BUNDLE_DIR}/platform-tools/adb"
    TEST_PROJECT_PATH="${TEST_DATA_DIR}/project.path"
}

make_sandbox() {
    mkdir -p "${RUNTIME_ROOT}" # the sandbox tests never run without it
    SANDBOX="$(mktemp -d "${RUNTIME_ROOT}/micsource-sandbox.XXXXXX")"
    SANDBOXES+=("${SANDBOX}")
    SANDBOX_HOME="${SANDBOX}/home"
    STUBBIN="${SANDBOX}/stubbin"
    STUB_LOG="${SANDBOX}/stub.log"
    TEST_STDOUT="${SANDBOX}/stdout.txt"
    TEST_STDERR="${SANDBOX}/stderr.txt"
    COMBINED="${SANDBOX}/combined.txt"
    TEST_XDG_DESKTOP=""
    mkdir -p "${SANDBOX_HOME}" "${STUBBIN}"
    : >"${STUB_LOG}"

    # Install paths as the scripts under test compute them.
    derive_test_paths

    # Logging stubs: every call appends "<name> <args>" to ${STUB_LOG}.
    # adb: get-state prints "offline" to stderr and exits 1; any other
    # subcommand exits 0 (so a non-get-state line in the log means the
    # installer did something beyond state probing).
    cat >"${STUBBIN}/adb" <<'STUB'
#!/bin/sh
printf 'adb %s\n' "$*" >> "${STUB_LOG}"
if [ "$1" = get-state ]; then
    echo offline >&2
    exit 1
fi
exit 0
STUB
    cat >"${STUBBIN}/systemctl" <<'STUB'
#!/bin/sh
printf 'systemctl %s\n' "$*" >> "${STUB_LOG}"
exit 0
STUB
    cat >"${STUBBIN}/gnome-extensions" <<'STUB'
#!/bin/sh
printf 'gnome-extensions %s\n' "$*" >> "${STUB_LOG}"
exit 0
STUB
    chmod +x "${STUBBIN}/adb" "${STUBBIN}/systemctl" "${STUBBIN}/gnome-extensions"
}

run_script() { # run_script <stdin-bytes> <script> [args...]
    local stdin_data="$1"
    shift
    RC=0
    printf '%s' "${stdin_data}" |
        env \
            HOME="${SANDBOX_HOME}" \
            XDG_CURRENT_DESKTOP="${TEST_XDG_DESKTOP:-GNOME}" \
            GNOME_DESKTOP_SESSION_ID="" \
            JAVA_HOME="" \
            ANDROID_HOME="" \
            NO_COLOR="" \
            STUB_LOG="${STUB_LOG}" \
            PATH="${STUBBIN}:/usr/bin:/bin" \
            bash "$@" \
            >"${TEST_STDOUT}" 2>"${TEST_STDERR}" ||
        RC=$?
}

combine_output() { # combine_output — merge the last run's stdout+stderr
    cat "${TEST_STDOUT}" "${TEST_STDERR}" >"${COMBINED}"
}

# Save/restore the current sandbox's globals so a later case can keep using
# it after an intermediate case switched to a fresh one. Paths are re-derived
# on restore rather than saved, so they cannot drift from SANDBOX_HOME.
save_sandbox() {
    SAVED_SANDBOX="${SANDBOX}"
    SAVED_SANDBOX_HOME="${SANDBOX_HOME}"
    SAVED_STUB_LOG="${STUB_LOG}"
    SAVED_TEST_STDOUT="${TEST_STDOUT}"
    SAVED_TEST_STDERR="${TEST_STDERR}"
    SAVED_COMBINED="${COMBINED}"
    SAVED_TEST_XDG_DESKTOP="${TEST_XDG_DESKTOP}"
}

restore_sandbox() {
    SANDBOX="${SAVED_SANDBOX}"
    SANDBOX_HOME="${SAVED_SANDBOX_HOME}"
    STUBBIN="${SANDBOX}/stubbin"
    STUB_LOG="${SAVED_STUB_LOG}"
    TEST_STDOUT="${SAVED_TEST_STDOUT}"
    TEST_STDERR="${SAVED_TEST_STDERR}"
    COMBINED="${SAVED_COMBINED}"
    TEST_XDG_DESKTOP="${SAVED_TEST_XDG_DESKTOP}"
    derive_test_paths
}

##############################################################################
# Fixture: a synthetic stand-in for everything an install previously left
# behind, so uninstall cases need no install.sh run.
##############################################################################
make_full_fixture() {
    mkdir -p \
        "${TEST_SYSTEMD_DIR}" \
        "${TEST_APPS_DIR}" \
        "${TEST_ICON_DIR}" \
        "${TEST_BIN_DIR}" \
        "${TEST_AUTOSTART_DIR}" \
        "${TEST_PIPEWIRE_DIR}" \
        "${TEST_EXT_DIR}" \
        "${TEST_CONFIG_DIR}" \
        "${TEST_DATA_DIR}"

    printf '[Unit]\nDescription=MicSource monitor (sandbox fixture)\n' >"${TEST_UNIT}"
    printf '[Desktop Entry]\nType=Application\nName=MicSource\n' >"${TEST_DESKTOP}"
    printf '<svg xmlns="http://www.w3.org/2000/svg"/>\n' >"${TEST_ICON}"
    printf '[Desktop Entry]\nType=Application\nName=MicSource Tray\n' >"${TEST_AUTOSTART}"
    printf 'stream.rules = micsource\n' >"${TEST_PULSE_LOCK}"
    printf '{ "name": "micsource-tile@micsource.local" }\n' >"${TEST_EXT_METADATA}"
    printf '[audio]\nenabled=true\n' >"${TEST_CONFIG_INI}"

    mkdir -p "${TEST_DATA_DIR}/adb-bundle/platform-tools"
    : >"${TEST_ADB_BUNDLE}"
    ln -s "${TEST_ADB_BUNDLE}" "${TEST_ADB_LINK}"
    ln -s "${TEST_DATA_DIR}/micsource" "${TEST_CLI_LINK}"

    # Data-dir markers that install.sh versions past and present write.
    : >"${TEST_DATA_DIR}/adb.path"
    : >"${TEST_DATA_DIR}/apk.path"
    : >"${TEST_DATA_DIR}/micsource"
    : >"${TEST_DATA_DIR}/micsource-monitor.py"
    : >"${TEST_DATA_DIR}/project.path"

    # The monitor's control socket, so case 3's assert_gone is not vacuous.
    python3 - "${TEST_SOCK}" <<'PY'
import socket
import sys

sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.bind(sys.argv[1])
sock.close()
PY
}

##############################################################################
# Case 1: --help
##############################################################################
case_uninstall_help() {
    start_case 1 "uninstall --help prints usage and exits 0"
    make_sandbox
    run_script "" "${UNINSTALL}" --help
    assert_exit 0 "${RC}"
    assert_contains "${TEST_STDOUT}" "Usage:"
    end_case
}

##############################################################################
# Case 2: unknown flag
##############################################################################
case_uninstall_unknown_flag() {
    start_case 2 "uninstall --bogus exits 2"
    make_sandbox
    run_script "" "${UNINSTALL}" --bogus
    assert_exit 2 "${RC}"
    assert_contains "${TEST_STDERR}" "Usage: uninstall.sh [--help]"
    end_case
}

##############################################################################
# Case 3: full removal against the synthetic fixture
##############################################################################
case_uninstall_full_removal() {
    start_case 3 "uninstall removes all fixture paths and calls systemd/gnome stubs"
    make_sandbox
    make_full_fixture
    # y = confirm the uninstall; y = also remove the adb bundle (the fixture
    # includes it because the PATH adb symlink only resolves when it exists).
    # Case 14 covers declining that second prompt.
    run_script $'y\ny\n' "${UNINSTALL}"
    assert_exit 0 "${RC}"
    assert_gone "${TEST_UNIT}"
    assert_gone "${TEST_DESKTOP}"
    assert_gone "${TEST_ICON}"
    assert_gone "${TEST_CLI_LINK}"
    assert_gone "${TEST_ADB_LINK}"
    assert_gone "${TEST_AUTOSTART}"
    assert_gone "${TEST_PULSE_LOCK}"
    assert_gone "${TEST_EXT_DIR}"
    assert_gone "${TEST_SOCK}"
    assert_gone "${TEST_CONFIG_DIR}"
    assert_gone "${TEST_DATA_DIR}"
    assert_gone "${TEST_ADB_BUNDLE}"
    assert_contains "${STUB_LOG}" "systemctl --user disable --now micsource.service"
    assert_contains "${STUB_LOG}" "gnome-extensions disable micsource-tile@micsource.local"
    end_case
}

##############################################################################
# Case 4: idempotency — a second run on the emptied sandbox stays quiet
##############################################################################
case_uninstall_idempotent() {
    start_case 4 "uninstall is idempotent on an emptied sandbox"
    make_sandbox
    make_full_fixture
    run_script $'y\nn\n' "${UNINSTALL}"
    assert_exit 0 "${RC}"
    run_script $'y\nn\n' "${UNINSTALL}"
    assert_exit 0 "${RC}"
    assert_not_contains "${TEST_STDERR}" "[ERR]"
    assert_not_contains "${TEST_STDOUT}" "[ERR]"
    end_case
}

##############################################################################
# Case 5: ownership guards keep foreign content in place
##############################################################################
case_uninstall_ownership_guards() {
    start_case 5 "uninstall leaves foreign data dir, config dir, and CLI symlink"
    make_sandbox
    # (a) data dir containing only foreign content
    mkdir -p "${TEST_DATA_DIR}"
    printf 'not ours\n' >"${TEST_DATA_DIR}/foreign.txt"
    # (b) config dir without config.ini
    mkdir -p "${TEST_CONFIG_DIR}"
    printf 'unrelated\n' >"${TEST_CONFIG_DIR}/other.txt"
    # (c) CLI symlink pointing somewhere else entirely
    mkdir -p "${TEST_BIN_DIR}"
    printf '#!/bin/sh\nexit 0\n' >"${SANDBOX}/elsewhere-target"
    ln -s "${SANDBOX}/elsewhere-target" "${TEST_CLI_LINK}"
    run_script $'y\n' "${UNINSTALL}"
    assert_exit 0 "${RC}"
    assert_file "${TEST_DATA_DIR}"
    assert_file "${TEST_CONFIG_DIR}"
    assert_file "${TEST_CLI_LINK}"
    end_case
}

##############################################################################
# Case 6: install happy path (asset-copy model)
##############################################################################
case_install_happy_path() {
    start_case 6 "install.sh installs assets, config, desktop, unit, icon, ext"
    make_sandbox
    run_script $'n\nn\n' "${INSTALL}"
    assert_exit 0 "${RC}"
    assert_file "${TEST_CONFIG_INI}"
    if [[ "$(stat -c '%a' "${TEST_CONFIG_INI}")" != "600" ]]; then
        fail_case "(${TEST_CONFIG_INI}) mode: expected 600, got $(stat -c '%a' "${TEST_CONFIG_INI}")"
    fi
    assert_file "${TEST_DESKTOP}"
    assert_file "${TEST_UNIT}"
    assert_file "${TEST_ICON}"
    local f
    for f in micsource micsource-gui micsource-build \
        micsource-app.py micsource-tray.py micsource-monitor.py; do
        assert_file "${TEST_DATA_DIR}/${f}"
        if [[ ! -x "${TEST_DATA_DIR}/${f}" ]]; then
            fail_case "expected executable payload: ${TEST_DATA_DIR}/${f}"
        fi
    done
    assert_file "${TEST_PROJECT_PATH}"
    assert_contains "${TEST_PROJECT_PATH}" "${REPO_ROOT}"
    assert_file "${TEST_CLI_LINK}"
    if [[ "$(readlink -f "${TEST_CLI_LINK}")" != "${TEST_DATA_DIR}/micsource" ]]; then
        fail_case "(${TEST_CLI_LINK}) points at $(readlink -f "${TEST_CLI_LINK}"), expected ${TEST_DATA_DIR}/micsource"
    fi
    assert_file "${TEST_EXT_METADATA}"
    assert_gone "${TEST_DATA_DIR}/gnome"
    assert_contains "${TEST_STDOUT}" "complete"
    assert_no_esc "${TEST_STDOUT}"
    # The device step must only probe state, never install/forward/shell
    # (Review Focus 2: no traffic may reach the connected phone).
    assert_contains "${STUB_LOG}" "adb get-state"
    local bad_adb
    bad_adb="$(grep '^adb ' "${STUB_LOG}" | grep -v '^adb get-state' || true)"
    if [[ -n "${bad_adb}" ]]; then
        fail_case "stub.log records adb activity beyond get-state: ${bad_adb}"
    fi
    assert_contains "${STUB_LOG}" "systemctl --user daemon-reload"
    # The installed assets are the audited copies: the CLI must carry its own
    # warn()/ask() helpers and micsource-build must read project.path.
    assert_matches "${TEST_DATA_DIR}/micsource" '^warn\(\)'
    assert_matches "${TEST_DATA_DIR}/micsource" '^ask\(\)'
    assert_matches "${TEST_DATA_DIR}/micsource-build" 'project\.path'
    save_sandbox
    end_case
}

##############################################################################
# Case 7: sanity preflight fails fast without python3
##############################################################################
case_install_python3_preflight() {
    start_case 7 "install exits 1 with a python3 error when python3 is absent"
    make_sandbox
    # Only uname and dirname are on PATH: the script must source common.sh
    # (whose INSTALL_DIR resolution needs dirname) before step_sanity runs,
    # where the Linux check precedes the python3 check and must succeed for
    # the preflight to be reached.
    mkdir -p "${RUNTIME_ROOT}/emptybin"
    ln -sf "$(command -v uname)" "${RUNTIME_ROOT}/emptybin/uname"
    ln -sf "$(command -v dirname)" "${RUNTIME_ROOT}/emptybin/dirname"
    RC=0
    env HOME="${SANDBOX_HOME}" PATH="${RUNTIME_ROOT}/emptybin" \
        /usr/bin/bash "${INSTALL}" \
        >"${TEST_STDOUT}" 2>"${TEST_STDERR}" || RC=$?
    assert_exit 1 "${RC}"
    assert_contains "${TEST_STDERR}" "python3"
    end_case
}

##############################################################################
# Case 8: round trip — uninstall removes everything a real install created
##############################################################################
case_install_uninstall_roundtrip() {
    start_case 8 "uninstall removes everything install.sh created"
    restore_sandbox
    : >"${STUB_LOG}" # isolate the uninstall's stub traffic
    run_script $'y\n' "${UNINSTALL}"
    assert_exit 0 "${RC}"
    assert_gone "${TEST_DATA_DIR}"
    assert_gone "${TEST_CONFIG_DIR}"
    assert_gone "${TEST_UNIT}"
    assert_gone "${TEST_DESKTOP}"
    assert_gone "${TEST_ICON}"
    assert_gone "${TEST_CLI_LINK}"
    assert_gone "${TEST_EXT_DIR}"
    assert_gone "${TEST_PULSE_LOCK}"
    assert_contains "${STUB_LOG}" "systemctl --user disable --now micsource.service"
    assert_contains "${STUB_LOG}" "gnome-extensions disable micsource-tile@micsource.local"
    end_case
}

##############################################################################
# Case 9: install.sh strict args (unknown flag / --help)
##############################################################################
case_install_args() {
    start_case 9 "install --bogus exits 2; --help prints usage and exits 0"
    make_sandbox
    run_script "" "${INSTALL}" --bogus
    assert_exit 2 "${RC}"
    run_script "" "${INSTALL}" --help
    assert_exit 0 "${RC}"
    assert_contains "${TEST_STDOUT}" "Usage:"
    end_case
}

##############################################################################
# Case 10: a failed REQUIRED step makes the installer exit 1
##############################################################################
case_install_required_failure() {
    start_case 10 "config step failing (dir in the way) exits 1 with config (FAILED)"
    make_sandbox
    # Occupy the config path with a directory: the config step cannot write
    # config.ini there and must fail the whole run (required step).
    mkdir -p "${TEST_CONFIG_DIR}"
    mkdir "${TEST_CONFIG_DIR}/config.ini"
    run_script $'n\nn\n' "${INSTALL}"
    assert_exit 1 "${RC}"
    combine_output
    assert_contains "${COMBINED}" "config (FAILED)"
    end_case
}

##############################################################################
# Case 11: a declined OPTIONAL step records skipped and keeps exit 0
##############################################################################
case_install_optional_skipped() {
    start_case 11 "declined build env records build_env (skipped) and exits 0"
    make_sandbox
    run_script $'n\nn\n' "${INSTALL}"
    assert_exit 0 "${RC}"
    combine_output
    assert_contains "${COMBINED}" "build_env (skipped)"
    end_case
}

##############################################################################
# Case 12: download failure — honest record, exit 0, no scratch left behind
##############################################################################
case_install_download_failure() {
    start_case 12 "failed bundle download records adb (FAILED), exits 0, cleans scratch"
    make_sandbox
    # Curated PATH (nothing else): symlinks to exactly the binaries install.sh
    # needs, plus logging stubs. It contains NO adb (so the bundle branch is
    # taken) and NO real curl/wget (so no host, even one with /usr/bin/adb or
    # network access, can be touched — the old ${dlbin}:/usr/bin:/bin PATH
    # leaked both). curl logs and exits 22; wget logs and exits 1.
    local dlbin="${SANDBOX}/dlstubbin"
    mkdir -p "${dlbin}"
    local tool tool_path
    for tool in bash uname dirname basename mktemp cp chmod cat mkdir ln \
        rm mv grep head sed tail python3 tr readlink sleep; do
        if tool_path="$(command -v "${tool}")"; then
            ln -sf "${tool_path}" "${dlbin}/${tool}"
        fi
    done
    # Never executed (the download fails first), but step_adb checks for it.
    cat >"${dlbin}/unzip" <<'STUB'
#!/bin/sh
printf 'unzip %s\n' "$*" >> "${STUB_LOG}"
exit 1
STUB
    cat >"${dlbin}/curl" <<'STUB'
#!/bin/sh
printf 'curl %s\n' "$*" >> "${STUB_LOG}"
exit 22
STUB
    cat >"${dlbin}/wget" <<'STUB'
#!/bin/sh
printf 'wget %s\n' "$*" >> "${STUB_LOG}"
exit 1
STUB
    cat >"${dlbin}/systemctl" <<'STUB'
#!/bin/sh
printf 'systemctl %s\n' "$*" >> "${STUB_LOG}"
exit 0
STUB
    cat >"${dlbin}/gnome-extensions" <<'STUB'
#!/bin/sh
printf 'gnome-extensions %s\n' "$*" >> "${STUB_LOG}"
exit 0
STUB
    chmod +x "${dlbin}/unzip" "${dlbin}/curl" "${dlbin}/wget" \
        "${dlbin}/systemctl" "${dlbin}/gnome-extensions"
    RC=0
    printf 'y\nn\n' |
        env \
            HOME="${SANDBOX_HOME}" \
            XDG_CURRENT_DESKTOP="GNOME" \
            GNOME_DESKTOP_SESSION_ID="" \
            JAVA_HOME="" \
            ANDROID_HOME="" \
            NO_COLOR="" \
            STUB_LOG="${STUB_LOG}" \
            PATH="${dlbin}" \
            /usr/bin/bash "${INSTALL}" \
            >"${TEST_STDOUT}" 2>"${TEST_STDERR}" || RC=$?
    assert_exit 0 "${RC}"
    combine_output
    assert_contains "${COMBINED}" "adb (FAILED)"
    assert_contains "${STUB_LOG}" "curl "
    # No command outside the curated dir may have run: a real adb would have
    # logged "adb ..." through the stubbin stub, which is not on this PATH.
    assert_not_contains "${STUB_LOG}" "adb get-state"
    local leftovers
    leftovers="$(find "${TEST_DATA_DIR}" -maxdepth 1 \( -name '.dl.*' -o -name '.platform-tools*' \) || true)"
    if [[ -n "${leftovers}" ]]; then
        fail_case "download scratch left behind: ${leftovers}"
    fi
    end_case
}

##############################################################################
# Case 13: non-GNOME desktop skips the extension and keeps exit 0
##############################################################################
case_install_non_gnome() {
    start_case 13 "XDG_CURRENT_DESKTOP=KDE skips gnome_ext and exits 0"
    make_sandbox
    TEST_XDG_DESKTOP="KDE"
    run_script $'n\nn\n' "${INSTALL}"
    assert_exit 0 "${RC}"
    assert_gone "${TEST_EXT_DIR}"
    combine_output
    assert_contains "${COMBINED}" "gnome_ext (skipped)"
    end_case
}

##############################################################################
# Case 14: uninstall keeps the adb bundle when the user declines it
##############################################################################
case_uninstall_keeps_bundle() {
    start_case 14 "uninstall keeps the adb bundle when the prompt is declined"
    make_sandbox
    make_full_fixture
    # y = confirm the uninstall; n = keep the adb bundle.
    run_script $'y\nn\n' "${UNINSTALL}"
    assert_exit 0 "${RC}"
    assert_file "${TEST_ADB_BUNDLE}"
    assert_file "${TEST_DATA_DIR}"
    # Only the bundle survives: none of the other fixture paths may remain.
    local leftovers
    leftovers="$(find "${TEST_DATA_DIR}" -mindepth 1 -maxdepth 1 ! -name adb-bundle || true)"
    if [[ -n "${leftovers}" ]]; then
        fail_case "data dir kept more than the adb bundle: ${leftovers}"
    fi
    assert_gone "${TEST_CONFIG_DIR}"
    assert_gone "${TEST_UNIT}"
    assert_gone "${TEST_SOCK}"
    combine_output
    assert_contains "${COMBINED}" "Kept adb bundle at ${TEST_ADB_BUNDLE_DIR}"
    end_case
}

##############################################################################
# Case 15: --with-tray installs the autostart entry on a fresh HOME
##############################################################################
case_install_with_tray() {
    start_case 15 "--with-tray writes the autostart entry on a fresh HOME"
    make_sandbox
    # n = decline the build env, n = decline the APK build.
    run_script $'n\nn\n' "${INSTALL}" --with-tray
    assert_exit 0 "${RC}"
    assert_file "${TEST_AUTOSTART}"
    assert_contains "${TEST_AUTOSTART}" "Exec=${TEST_DATA_DIR}/micsource-tray.py"
    assert_contains "${TEST_AUTOSTART}" "X-GNOME-Autostart-enabled=true"
    combine_output
    assert_not_contains "${COMBINED}" "tray (FAILED)"
    end_case
}

##############################################################################
# Case 16: an unwritable required dir fails the step instead of recording ok
##############################################################################
case_install_readonly_config() {
    start_case 16 "unwritable config dir fails the config step (exit 1, no complete)"
    make_sandbox
    # The dir exists (so step_sanity's mkdir -p succeeds) but cannot be
    # written: the config step's write must be recorded as failed rather than
    # falling through to "Config written" (set -e is suspended inside
    # run_step's `||` context).
    mkdir -p "${TEST_CONFIG_DIR}"
    chmod 555 "${TEST_CONFIG_DIR}"
    run_script $'n\nn\n' "${INSTALL}"
    chmod 755 "${TEST_CONFIG_DIR}" # let the sandbox cleanup remove it
    assert_exit 1 "${RC}"
    combine_output
    assert_contains "${COMBINED}" "config (FAILED)"
    assert_not_contains "${COMBINED}" "install complete"
    assert_gone "${TEST_CONFIG_INI}"
    end_case
}

# Invoked via `trap cleanup EXIT`; shellcheck cannot see that call → false
# positive SC2317.
# shellcheck disable=SC2317
cleanup() {
    local s
    for s in ${SANDBOXES[@]+"${SANDBOXES[@]}"}; do
        rm -rf -- "${s}"
    done
}

main() {
    trap cleanup EXIT

    case_uninstall_help
    case_uninstall_unknown_flag
    case_uninstall_full_removal
    case_uninstall_idempotent
    case_uninstall_ownership_guards
    case_install_happy_path
    case_install_python3_preflight
    case_install_uninstall_roundtrip
    case_install_args
    case_install_required_failure
    case_install_optional_skipped
    case_install_download_failure
    case_install_non_gnome
    case_uninstall_keeps_bundle
    case_install_with_tray
    case_install_readonly_config

    printf '\n%d passed, %d failed\n' "${PASSED}" "${FAILED}"
    ((FAILED == 0)) || exit 1
    exit 0
}

main
