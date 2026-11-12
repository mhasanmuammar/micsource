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
RC=0

SAVED_SANDBOX=""
SAVED_SANDBOX_HOME=""
SAVED_STUB_LOG=""
SAVED_TEST_STDOUT=""
SAVED_TEST_STDERR=""

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
make_sandbox() {
    mkdir -p "${RUNTIME_ROOT}" # the sandbox tests never run without it
    SANDBOX="$(mktemp -d "${RUNTIME_ROOT}/micsource-sandbox.XXXXXX")"
    SANDBOXES+=("${SANDBOX}")
    SANDBOX_HOME="${SANDBOX}/home"
    STUBBIN="${SANDBOX}/stubbin"
    STUB_LOG="${SANDBOX}/stub.log"
    TEST_STDOUT="${SANDBOX}/stdout.txt"
    TEST_STDERR="${SANDBOX}/stderr.txt"
    mkdir -p "${SANDBOX_HOME}" "${STUBBIN}"
    : >"${STUB_LOG}"

    # Install paths as the scripts under test compute them.
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
    TEST_ADB_BUNDLE="${TEST_DATA_DIR}/adb-bundle/platform-tools/adb"
    TEST_PROJECT_PATH="${TEST_DATA_DIR}/project.path"

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
            XDG_CURRENT_DESKTOP="GNOME" \
            STUB_LOG="${STUB_LOG}" \
            PATH="${STUBBIN}:/usr/bin:/bin" \
            bash "$@" \
            >"${TEST_STDOUT}" 2>"${TEST_STDERR}" ||
        RC=$?
}

# Save/restore the current sandbox's globals so a later case can keep using
# it after an intermediate case switched to a fresh one.
save_sandbox() {
    SAVED_SANDBOX="${SANDBOX}"
    SAVED_SANDBOX_HOME="${SANDBOX_HOME}"
    SAVED_STUB_LOG="${STUB_LOG}"
    SAVED_TEST_STDOUT="${TEST_STDOUT}"
    SAVED_TEST_STDERR="${TEST_STDERR}"
}

restore_sandbox() {
    SANDBOX="${SAVED_SANDBOX}"
    SANDBOX_HOME="${SAVED_SANDBOX_HOME}"
    STUBBIN="${SANDBOX}/stubbin"
    STUB_LOG="${SAVED_STUB_LOG}"
    TEST_STDOUT="${SAVED_TEST_STDOUT}"
    TEST_STDERR="${SAVED_TEST_STDERR}"
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
    # y = confirm the uninstall; n = decline the adb-bundle question
    # (the fixture includes the bundle because the PATH adb symlink only
    # resolves when it exists). The data dir is wiped either way.
    run_script $'y\nn\n' "${UNINSTALL}"
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

    printf '\n%d passed, %d failed\n' "${PASSED}" "${FAILED}"
    ((FAILED == 0)) || exit 1
    exit 0
}

main
