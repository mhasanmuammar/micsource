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
APK_VERIFY="${REPO_ROOT}/linux-install/assets/micsource-apk-verify"
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
TEST_PATH=""
RC=0

SAVED_SANDBOX=""
SAVED_SANDBOX_HOME=""
SAVED_STUB_LOG=""
SAVED_TEST_STDOUT=""
SAVED_TEST_STDERR=""
SAVED_COMBINED=""
SAVED_TEST_XDG_DESKTOP=""
SAVED_TEST_PATH=""

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
    TEST_PATH="${STUBBIN}:/usr/bin:/bin"
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
            PATH="${TEST_PATH}" \
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
    SAVED_TEST_PATH="${TEST_PATH}"
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
    TEST_PATH="${SAVED_TEST_PATH}"
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

    # A filesystem marker is sufficient: uninstall removes the socket path
    # with rm -f, and this sandbox may deny AF_UNIX bind() via seccomp.
    : >"${TEST_SOCK}"
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
    start_case 5 "uninstall preserves foreign data/config dirs and CLI/adb links"
    make_sandbox
    # (a) data dir containing only foreign content
    mkdir -p "${TEST_DATA_DIR}"
    printf 'not ours\n' >"${TEST_DATA_DIR}/foreign.txt"
    # (b) config dir without config.ini
    mkdir -p "${TEST_CONFIG_DIR}"
    printf 'unrelated\n' >"${TEST_CONFIG_DIR}/other.txt"
    # (c) CLI and adb symlinks pointing somewhere else entirely
    mkdir -p "${TEST_BIN_DIR}"
    printf '#!/bin/sh\nexit 0\n' >"${SANDBOX}/elsewhere-target"
    ln -s "${SANDBOX}/elsewhere-target" "${TEST_CLI_LINK}"
    ln -s "${SANDBOX}/elsewhere-target" "${TEST_ADB_LINK}"
    run_script $'y\n' "${UNINSTALL}"
    assert_exit 0 "${RC}"
    assert_file "${TEST_DATA_DIR}"
    assert_file "${TEST_CONFIG_DIR}"
    assert_file "${TEST_CLI_LINK}"
    assert_file "${TEST_ADB_LINK}"
    if [[ "$(readlink "${TEST_ADB_LINK}")" != "${SANDBOX}/elsewhere-target" ]]; then
        fail_case "uninstall changed foreign adb symlink target"
    fi
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
    for f in micsource micsource-gui micsource-build micsource-apk-verify \
        micsource-app.py micsource-tray.py micsource-monitor.py micsource_adb.py; do
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
    assert_gone "${TEST_ADB_LINK}"
    assert_contains "${TEST_CONFIG_INI}" "server_port = 5038"
    assert_contains "${TEST_STDOUT}" "complete"
    assert_no_esc "${TEST_STDOUT}"
    # The device step must only probe state, never install/forward/shell
    # (Review Focus 2: no traffic may reach the connected phone).
    assert_contains "${STUB_LOG}" "adb -P 5038 get-state"
    local bad_adb
    bad_adb="$(grep '^adb ' "${STUB_LOG}" | grep -v '^adb -P 5038 get-state' || true)"
    if [[ -n "${bad_adb}" ]]; then
        fail_case "stub.log records adb activity beyond get-state: ${bad_adb}"
    fi
    assert_contains "${STUB_LOG}" "systemctl --user daemon-reload"
    # The installed assets are the audited copies: the CLI must carry its own
    # warn()/ask() helpers and micsource-build must read project.path.
    assert_matches "${TEST_DATA_DIR}/micsource" '^warn\(\)'
    assert_matches "${TEST_DATA_DIR}/micsource" '^ask\(\)'
    assert_matches "${TEST_DATA_DIR}/micsource-build" 'project\.path'
    assert_matches "${TEST_DATA_DIR}/micsource_adb.py" 'def validate_server_port'
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
        rm mv grep head sed tail python3 tr readlink sleep sha256sum sha1sum; do
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
    assert_not_contains "${STUB_LOG}" "adb -P 5038 get-state"
    local leftovers
    leftovers="$(find "${TEST_DATA_DIR}" -maxdepth 1 \( -name '.dl.*' -o -name '.platform-tools*' \) || true)"
    if [[ -n "${leftovers}" ]]; then
        fail_case "download scratch left behind: ${leftovers}"
    fi
    end_case
}

##############################################################################
# Case 18: a checksum mismatch rejects the archive before extraction
##############################################################################
case_install_checksum_mismatch() {
    start_case 18 "platform-tools checksum mismatch fails before unzip"
    make_sandbox
    local dlbin="${SANDBOX}/checksum-stubbin"
    mkdir -p "${dlbin}"
    local tool tool_path
    for tool in bash uname dirname basename mktemp cp chmod cat mkdir ln \
        rm mv grep head sed tail python3 tr readlink sleep sha256sum sha1sum; do
        if tool_path="$(command -v "${tool}")"; then
            ln -sf "${tool_path}" "${dlbin}/${tool}"
        fi
    done
    cat >"${dlbin}/curl" <<'STUB'
#!/bin/sh
printf 'curl %s\n' "$*" >> "${STUB_LOG}"
while [ "$#" -gt 0 ]; do
    if [ "$1" = -o ]; then
        shift
        printf 'not the pinned archive\n' > "$1"
        exit 0
    fi
    shift
done
exit 2
STUB
    cat >"${dlbin}/unzip" <<'STUB'
#!/bin/sh
printf 'unzip %s\n' "$*" >> "${STUB_LOG}"
exit 0
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
    chmod +x "${dlbin}/curl" "${dlbin}/unzip" "${dlbin}/systemctl" \
        "${dlbin}/gnome-extensions"
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
    assert_contains "${COMBINED}" "SHA-256 verification failed"
    assert_contains "${COMBINED}" "adb (FAILED)"
    assert_not_contains "${STUB_LOG}" "unzip "
    assert_gone "${TEST_ADB_BUNDLE_DIR}/platform-tools"
    end_case
}

##############################################################################
# Case 19: APK verifier checks through apksigner and rejects invalid signatures
##############################################################################
case_apk_signature_verification() {
    start_case 19 "APK verifier accepts valid signatures and rejects invalid ones"
    make_sandbox
    local sdk="${SANDBOX}/android-sdk"
    local apk="${SANDBOX}/sample.apk"
    mkdir -p "${TEST_DATA_DIR}" "${sdk}/build-tools/34.0.0"
    printf 'ANDROID_HOME=%s\n' "${sdk}" >"${TEST_DATA_DIR}/build-env.path"
    printf 'fixture APK\n' >"${apk}"
    cat >"${sdk}/build-tools/34.0.0/apksigner" <<'STUB'
#!/bin/sh
printf 'apksigner %s\n' "$*" >> "${STUB_LOG}"
printf 'WARNING: benign META-INF metadata\n'
exit "${APKSIGNER_RESULT:-0}"
STUB
    chmod +x "${sdk}/build-tools/34.0.0/apksigner"

    RC=0
    env HOME="${SANDBOX_HOME}" STUB_LOG="${STUB_LOG}" PATH="/usr/bin:/bin" \
        bash "${APK_VERIFY}" "${apk}" >"${TEST_STDOUT}" 2>"${TEST_STDERR}" || RC=$?
    assert_exit 0 "${RC}"
    assert_contains "${STUB_LOG}" "apksigner verify ${apk}"
    assert_not_contains "${TEST_STDOUT}${TEST_STDERR}" "WARNING: benign META-INF metadata"

    RC=0
    env HOME="${SANDBOX_HOME}" STUB_LOG="${STUB_LOG}" APKSIGNER_RESULT=1 \
        PATH="/usr/bin:/bin" bash "${APK_VERIFY}" "${apk}" \
        >"${TEST_STDOUT}" 2>"${TEST_STDERR}" || RC=$?
    assert_exit 1 "${RC}"
    assert_contains "${TEST_STDERR}" "APK signature verification failed"
    end_case
}

##############################################################################
# Case 20: install-apk verifies before any adb install command
##############################################################################
case_cli_install_requires_valid_apk_signature() {
    start_case 20 "install-apk refuses invalid signatures before adb install"
    make_sandbox
    local sdk="${SANDBOX}/android-sdk"
    local apk="${TEST_DATA_DIR}/micsource-release.apk"
    mkdir -p "${TEST_DATA_DIR}" "${sdk}/build-tools/34.0.0"
    printf '%s\n' "${STUBBIN}/adb" >"${TEST_DATA_DIR}/adb.path"
    printf 'ANDROID_HOME=%s\n' "${sdk}" >"${TEST_DATA_DIR}/build-env.path"
    printf 'fixture APK\n' >"${apk}"
    cp "${APK_VERIFY}" "${TEST_DATA_DIR}/micsource-apk-verify"
    chmod 755 "${TEST_DATA_DIR}/micsource-apk-verify"
    cat >"${STUBBIN}/adb" <<'STUB'
#!/bin/sh
printf 'adb %s\n' "$*" >> "${STUB_LOG}"
exit 0
STUB
    cat >"${sdk}/build-tools/34.0.0/apksigner" <<'STUB'
#!/bin/sh
printf 'apksigner %s\n' "$*" >> "${STUB_LOG}"
exit "${APKSIGNER_RESULT:-0}"
STUB
    chmod +x "${STUBBIN}/adb" "${sdk}/build-tools/34.0.0/apksigner"

    RC=0
    env HOME="${SANDBOX_HOME}" STUB_LOG="${STUB_LOG}" APKSIGNER_RESULT=1 \
        PATH="${STUBBIN}:/usr/bin:/bin" bash "${REPO_ROOT}/linux-install/assets/micsource" \
        install-apk >"${TEST_STDOUT}" 2>"${TEST_STDERR}" || RC=$?
    assert_exit 1 "${RC}"
    assert_not_contains "${STUB_LOG}" "adb install"
    assert_contains "${TEST_STDERR}" "Refusing to install an APK without a valid signature."

    : >"${STUB_LOG}"
    RC=0
    env HOME="${SANDBOX_HOME}" STUB_LOG="${STUB_LOG}" PATH="${STUBBIN}:/usr/bin:/bin" \
        bash "${REPO_ROOT}/linux-install/assets/micsource" install-apk \
        >"${TEST_STDOUT}" 2>"${TEST_STDERR}" || RC=$?
    assert_exit 0 "${RC}"
    assert_contains "${STUB_LOG}" "adb -P 5038 install -r -t ${apk}"
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

##############################################################################
# Case 17: --no-device skips adb setup and device traffic
##############################################################################
case_install_no_device() {
    start_case 17 "--no-device installs host files without invoking adb"
    make_sandbox
    run_script $'n\nn\n' "${INSTALL}" --no-device
    assert_exit 0 "${RC}"
    assert_file "${TEST_CONFIG_INI}"
    combine_output
    assert_contains "${COMBINED}" "adb (skipped)"
    assert_contains "${COMBINED}" "device (skipped)"
    if grep -q '^adb ' "${STUB_LOG}"; then
        fail_case "adb was invoked despite --no-device: $(cat "${STUB_LOG}")"
    fi
    end_case
}

##############################################################################
# Case 21: a legacy MicSource adb PATH link is removed and not recreated
##############################################################################
case_install_migrates_adb_link() {
    start_case 21 "install removes legacy bundled adb PATH link without recreating it"
    make_sandbox
    mkdir -p "${TEST_ADB_BUNDLE_DIR}/platform-tools" "${TEST_BIN_DIR}"
    cp "${STUBBIN}/adb" "${TEST_ADB_BUNDLE}"
    chmod 755 "${TEST_ADB_BUNDLE}"
    ln -s "${TEST_ADB_BUNDLE}" "${TEST_ADB_LINK}"
    mv "${STUBBIN}/adb" "${STUBBIN}/adb.disabled"
    ln -s "$(command -v python3)" "${STUBBIN}/python3"
    TEST_PATH="${STUBBIN}:/bin"
    if PATH="${TEST_PATH}" command -v adb >/dev/null 2>&1; then
        info "Skipping isolated bundle fixture because /bin also provides adb."
        end_case
        return
    fi

    run_script $'n\nn\n' "${INSTALL}"
    assert_exit 0 "${RC}"
    assert_gone "${TEST_ADB_LINK}"
    assert_contains "${TEST_DATA_DIR}/adb.path" "${TEST_ADB_BUNDLE}"
    assert_contains "${STUB_LOG}" "adb -P 5038 get-state"
    end_case
}

##############################################################################
# Case 23: uninstall removes an owned link but preserves a foreign adb link
##############################################################################
case_uninstall_preserves_foreign_adb_link() {
    start_case 23 "uninstall preserves foreign adb symlink while removing MicSource"
    make_sandbox
    make_full_fixture
    rm -f "${TEST_ADB_LINK}"
    printf '#!/bin/sh\nexit 0\n' >"${SANDBOX}/foreign-adb"
    ln -s "${SANDBOX}/foreign-adb" "${TEST_ADB_LINK}"

    run_script $'y\ny\n' "${UNINSTALL}"
    assert_exit 0 "${RC}"
    assert_gone "${TEST_DATA_DIR}"
    assert_file "${TEST_ADB_LINK}"
    if [[ "$(readlink "${TEST_ADB_LINK}")" != "${SANDBOX}/foreign-adb" ]]; then
        fail_case "uninstall changed foreign adb symlink target"
    fi
    end_case
}

##############################################################################
# Case 22: CLI uses the configured private ADB port for every request
##############################################################################
case_cli_uses_configured_adb_port() {
    start_case 22 "CLI routes all adb requests through configured private port"
    make_sandbox
    mkdir -p "${TEST_DATA_DIR}" "${TEST_CONFIG_DIR}"
    cp "${REPO_ROOT}/linux-install/assets/micsource" "${TEST_DATA_DIR}/micsource"
    chmod 755 "${TEST_DATA_DIR}/micsource"
    cat >"${TEST_CONFIG_INI}" <<EOF
[adb]
adb_path = ${STUBBIN}/adb
server_port = 5042
EOF

    run_script "" "${REPO_ROOT}/linux-install/assets/micsource" status
    assert_exit 0 "${RC}"
    assert_contains "${STUB_LOG}" "adb -P 5042 get-state"
    assert_contains "${STUB_LOG}" "adb -P 5042 forward --list"
    local bad_adb
    bad_adb="$(grep '^adb ' "${STUB_LOG}" | grep -v '^adb -P 5042 ' || true)"
    if [[ -n "${bad_adb}" ]]; then
        fail_case "CLI invoked adb outside configured port 5042: ${bad_adb}"
    fi
    end_case
}

##############################################################################
# Case 24: CLI refuses the system ADB server port
##############################################################################
case_cli_rejects_system_adb_port() {
    start_case 24 "CLI refuses port 5037 instead of sharing system ADB server"
    make_sandbox
    mkdir -p "${TEST_DATA_DIR}" "${TEST_CONFIG_DIR}"
    cp "${REPO_ROOT}/linux-install/assets/micsource" "${TEST_DATA_DIR}/micsource"
    chmod 755 "${TEST_DATA_DIR}/micsource"
    cat >"${TEST_CONFIG_INI}" <<EOF
[adb]
adb_path = ${STUBBIN}/adb
server_port = 5037
EOF

    run_script "" "${REPO_ROOT}/linux-install/assets/micsource" status
    assert_exit 2 "${RC}"
    assert_contains "${TEST_STDERR}" "reserved for system ADB"
    if grep -q '^adb ' "${STUB_LOG}"; then
        fail_case "CLI invoked adb with reserved port 5037"
    fi
    end_case
}

##############################################################################
# Case 25: verifier accepts a real AGP-built APK (META-INF metadata/version
# entries present) — the -Werr false-refusal regression
##############################################################################
case_apk_verify_agp_style_metadata() {
    local title="Verifier accepts real signed APK with AGP META-INF metadata"
    local apk_src="${REPO_ROOT}/app/build/outputs/apk/debug/app-debug.apk"
    [[ -f "${apk_src}" ]] || apk_src="${REPO_ROOT}/app/build/outputs/apk/release/app-release.apk"
    if [[ ! -f "${apk_src}" ]]; then
        printf 'SKIP: %s (no build output; run ./gradlew assembleDebug first)\n' "${title}"
        return 0
    fi
    local apksigner=""
    local sdk
    sdk="$(awk -F= '/^sdk\.dir=/{print $2}' "${REPO_ROOT}/local.properties" 2>/dev/null || true)"
    if [[ -z "${sdk}" || ! -d "${sdk}" ]]; then
        sdk="${HOME}/.local/share/micsource/build-env/android-sdk"
    fi
    apksigner="$(ls "${sdk}"/build-tools/*/apksigner 2>/dev/null | tail -n 1 || true)"
    if [[ -z "${apksigner}" || ! -x "${apksigner}" ]]; then
        printf 'SKIP: %s (real apksigner unavailable)\n' "${title}"
        return 0
    fi

    start_case 25 "${title}"
    make_sandbox

    # A real AGP-built APK must be accepted: it carries informational
    # warnings (META-INF metadata/version entries not covered by the v1
    # scheme, though covered by the v2 whole-file signature).
    RC=0
    bash "${APK_VERIFY}" "${apk_src}" >"${TEST_STDOUT}" 2>"${TEST_STDERR}" || RC=$?
    assert_exit 0 "${RC}"

    # Tampering after signing must still be refused.
    local tampered="${SANDBOX}/tampered.apk"
    cp "${apk_src}" "${tampered}"
    python3 - "${tampered}" <<'PY'
import os, sys, zipfile
apk = sys.argv[1]
tmp = apk + ".tmp"
with zipfile.ZipFile(apk) as zin, zipfile.ZipFile(tmp, "w") as zout:
    for item in zin.infolist():
        data = zin.read(item.filename)
        if item.filename == "AndroidManifest.xml":
            data = b"tampered"
        zout.writestr(item, data)
os.replace(tmp, apk)
PY
    RC=0
    bash "${APK_VERIFY}" "${tampered}" >"${TEST_STDOUT}" 2>"${TEST_STDERR}" || RC=$?
    assert_exit 1 "${RC}"
    assert_contains "${TEST_STDERR}" "APK signature verification failed"
    end_case
}

##############################################################################
# Case 26: device install honours the configured serial when both USB and
# Wi-Fi transports are online (plain `adb get-state` is ambiguous then)
##############################################################################
case_install_device_with_serial() {
    start_case 26 "device step honours the configured serial with USB+Wi-Fi online"
    make_sandbox
    mkdir -p "${TEST_CONFIG_DIR}"
    cat >"${TEST_CONFIG_INI}" <<'EOF'
[adb]
server_port = 5038

[device]
serial = wifi-serial
EOF
    cat >"${STUBBIN}/adb" <<'STUB'
#!/bin/sh
printf 'adb %s\n' "$*" >> "${STUB_LOG}"
case " $* " in
    *" get-state "*)
        case " $* " in
            *" -s wifi-serial "*) echo device; exit 0 ;;
            *) echo "error: more than one device/emulator" >&2; exit 1 ;;
        esac
        ;;
esac
exit 0
STUB
    chmod +x "${STUBBIN}/adb"
    cat >"${STUBBIN}/apksigner" <<'STUB'
#!/bin/sh
printf 'apksigner %s\n' "$*" >> "${STUB_LOG}"
exit 0
STUB
    chmod +x "${STUBBIN}/apksigner"
    # The verifier resolves the SDK from build-env.path (run_script clears
    # ANDROID_HOME) and uses its apksigner before PATH.
    mkdir -p "${TEST_DATA_DIR}" "${SANDBOX}/android-sdk/build-tools/34.0.0"
    printf 'ANDROID_HOME=%s\n' "${SANDBOX}/android-sdk" >"${TEST_DATA_DIR}/build-env.path"
    ln -sf "${STUBBIN}/apksigner" "${SANDBOX}/android-sdk/build-tools/34.0.0/apksigner"

    run_script $'n\nn\n' "${INSTALL}"
    assert_exit 0 "${RC}"
    combine_output
    assert_contains "${COMBINED}" "APK installed on device."
    assert_not_contains "${COMBINED}" "device (skipped)"
    assert_contains "${STUB_LOG}" "adb -P 5038 -s wifi-serial get-state"
    assert_contains "${STUB_LOG}" \
        "adb -P 5038 -s wifi-serial forward localabstract:micsource localabstract:audiosource"
    local install_line
    install_line="$(grep ' install ' "${STUB_LOG}" || true)"
    if [[ "${install_line}" != *"adb -P 5038 -s wifi-serial install "* ]]; then
        fail_case "APK install did not target the configured serial: ${install_line}"
    fi
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
    case_install_no_device
    case_install_checksum_mismatch
    case_apk_signature_verification
    case_cli_install_requires_valid_apk_signature
    case_install_migrates_adb_link
    case_cli_uses_configured_adb_port
    case_uninstall_preserves_foreign_adb_link
    case_cli_rejects_system_adb_port
    case_apk_verify_agp_style_metadata
    case_install_device_with_serial

    printf '\n%d passed, %d failed\n' "${PASSED}" "${FAILED}"
    ((FAILED == 0)) || exit 1
    exit 0
}

main
