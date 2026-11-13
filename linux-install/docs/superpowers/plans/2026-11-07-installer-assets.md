# Installer Assets Refactor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn `linux-install/` into a lint-clean, asset-based installer: payloads live as real files under `linux-install/assets/` (the source of truth), both scripts share `common.sh`, the two audited bugs are fixed, and install/uninstall report honest results with honest exit codes.

**Architecture:** install.sh stops embedding ~2,500 lines of generated Python/shell/JS in heredocs; it sources `common.sh` for shared helpers/paths and copies `assets/*` into `~/.local/share/micsource/` (GNOME extension files install straight from `assets/gnome/` into the extension dir — installed layout unchanged). Small `$VAR` templates (config.ini, .desktop, autostart, unit, pipewire lock) stay inline as heredocs. A committed sandbox test (`tests/test_install_sandbox.sh`) drives install + uninstall in a fake `$HOME` with stubbed external commands.

**Tech Stack:** Bash 4+ (strict mode), shellcheck v0.10.0, shfmt v3.8.0, Python 3 (`py_compile`, stdlib `unittest`), Node (`--check` for ESM syntax).

**Spec:** `linux-install/docs/superpowers/specs/2026-11-07-installer-assets-design.md`

## Global Constraints

- Work directly on `master` (session convention: explicit commit-to-master; no worktree).
- Assets in-repo are the source of truth. Seed `assets/micsource-app.py` and `assets/micsource-tray.py` **byte-identical** from `~/.local/share/micsource/` (deployed copies, verified ahead of heredocs on 2026-11-07). Seed `assets/{micsource,micsource-gui,micsource-build,micsource-monitor.py}` from the install.sh heredocs (verified byte-identical to deployed). Seed `assets/gnome/*` from the install.sh heredocs (extension.js verified identical to the deployed extension dir).
- After seeding, **Python and JS assets are byte-identical to their sources — never edited.** Shell assets (`micsource`, `micsource-gui`, `micsource-build`) may receive behavior-preserving lint fixes plus exactly the two named bug fixes; `# shellcheck disable` only for genuine false positives.
- Installed file layout must not change: **no `DATA_DIR/gnome/`**; the icon comes from `${PROJECT_ROOT}/assets/icon.svg` (drop the inline SVG heredoc, keep writing `micsource-icon.svg` as an ownership marker).
- Exit codes: `0` = success (optional steps may be skipped/failed), `1` = a required step failed, `2` = usage error (unknown flag).
- Required steps: `assets`, `config`, `desktop`, `cli`, `systemd`. Optional: `adb`, `build_env`, `apk`, `device`, `tray`, `gnome_ext`, `pipewire`. `step_sanity` failure exits immediately with 1 (nothing installed yet).
- GNOME extension installs iff `XDG_CURRENT_DESKTOP` or `GNOME_DESKTOP_SESSION_ID` matches `*GNOME*` case-insensitively; otherwise info-skip with enable instructions.
- Colors: ANSI only when `[[ -t 1 ]]` and `NO_COLOR` is unset; otherwise empty strings.
- Tooling: shellcheck **v0.10.0** and shfmt **v3.8.0** static binaries into `/tmp/opencode/bin` (official GitHub releases; x86_64 — check `uname -m`). Nothing installed system-wide. Acceptance: `shellcheck` zero warnings, `shfmt -d -i 4` (no `-ci` — existing case labels are not indented), no tabs.
- Sandbox testing only under `/tmp/opencode/...` until the one sanctioned real-HOME run (Task 7). Sandbox runs must stub `adb`, `systemctl`, `gnome-extensions` (shadowing the real ones via PATH precedence) — a non-stubbed run would stop the live service, disable the live GNOME extension, restart pipewire-pulse, or touch the connected phone.
- Deployed tray/app may still be edited by the user during this work: re-diff at the end (Task 7); if drifted, re-seed from deployed and re-verify once; if it drifts again mid-verification, halt and report.
- Messages in English; `set -euo pipefail` in every shell file; conventional commit messages.

## Review Focus

Failure modes the spec implies but no single task's happy path exercises — each pinned to the task that owns the code:

1. **Sandbox tests mutating the live user session** (`systemctl --user disable --now micsource.service` stops the real monitor; `gnome-extensions disable` disables the real pill) → Task 3's test asserts the `systemctl`/`gnome-extensions` stub logs received the expected calls (empty log = fail); Task 4 asserts the `systemctl` stub logged `daemon-reload`.
2. **A test run reaching the connected phone** (`adb install`/`forward`/`shell` against device `15010044525445343203be75e2a55b`) → Task 4's test asserts the `adb` stub log contains only `get-state` lines; Task 7's real run stubs `adb` only and restores `adb.path` byte-identical.
3. **Deployed tray/app drifting mid-work** (next install would silently revert the user's newest edits) → Task 7's final re-diff step with the re-seed-once/halt policy.
4. **Exit-code policy masking real breakage** (required step fails, installer still claims success) → Task 5's tests: required-fail run exits 1 with `[FAIL]` in the summary; optional-skip run exits 0 with `[SKIP]` recorded.
5. **The two audited bugs regressing** (`micsource stop` SIGKILL path and `install-apk` signature-conflict path dying with `command not found`; build helper hardcoding the old path) → Task 2's behavioral tests with `pkill`/`adb` stubs and the `project.path` missing/malformed cases.

---

### Task 1: Seed assets and retarget the tray test

**Files:**
- Create: `linux-install/assets/micsource`, `linux-install/assets/micsource-gui`, `linux-install/assets/micsource-build`, `linux-install/assets/micsource-monitor.py`, `linux-install/assets/micsource-app.py`, `linux-install/assets/micsource-tray.py`, `linux-install/assets/gnome/extension.js`, `linux-install/assets/gnome/prefs.js`, `linux-install/assets/gnome/metadata.json`
- Modify: `linux-install/tests/test_tray_model.py:13` (`TRAY` path)
- Test: byte-identity diffs, `py_compile`, the retargeted unittest, `node --check`

**Interfaces:**
- Consumes: heredoc payloads inside `install.sh`; deployed files `~/.local/share/micsource/{micsource-app.py,micsource-tray.py}` and `~/.local/share/gnome-shell/extensions/micsource-tile@micsource.local/*`.
- Produces: the nine asset files at the exact paths above; `TRAY` in `test_tray_model.py` = `os.path.join(REPO, "linux-install/assets/micsource-tray.py")` where `REPO` is resolved from `__file__` (`../../..` from the test file). Later tasks copy these files and never re-seed except per the Task 7 drift policy.

- [ ] **Step 1: Extract the heredoc payloads into assets**

From `linux-install/install.sh`, extract the bodies between the quoted heredoc markers (delimiter lines are bare, e.g. `__CLIEOF__`) into the matching asset path: `__CLIEOF__` → `assets/micsource`, `__GUIEOF__` → `assets/micsource-gui`, `__BUILDEOF__` → `assets/micsource-build`, `__MONITOREOF__` → `assets/micsource-monitor.py`, `__EXTJSEOF__` → `assets/gnome/extension.js`, `__PREFSEOF__` → `assets/gnome/prefs.js`, `__METADATAEOF__` → `assets/gnome/metadata.json`. An `awk` one-liner works: print lines after the marker line containing `<<'…'` until the bare delimiter.

- [ ] **Step 2: Copy the two deployed Python payloads**

```bash
cp ~/.local/share/micsource/micsource-app.py  linux-install/assets/micsource-app.py
cp ~/.local/share/micsource/micsource-tray.py linux-install/assets/micsource-tray.py
```

- [ ] **Step 3: Verify byte-identity of every seed**

Run and require zero output from each `diff` (SAME):
- `diff` each of `assets/{micsource,micsource-gui,micsource-build,micsource-monitor.py}` against `~/.local/share/micsource/<same name>`.
- `diff` `assets/gnome/extension.js`, `prefs.js`, `metadata.json` against `~/.local/share/gnome-shell/extensions/micsource-tile@micsource.local/<same name>`.
- `diff` `assets/micsource-app.py` and `assets/micsource-tray.py` against their deployed sources (trivially identical — guards against a copy typo).

If any diff is non-empty: stop and report (do not edit either side).

- [ ] **Step 4: Syntax-check the seeds**

```bash
python3 -m py_compile linux-install/assets/micsource-{app,tray,monitor}.py
bash -n linux-install/assets/{micsource,micsource-gui,micsource-build}
mkdir -p /tmp/opencode/nodecheck && for f in extension prefs; do
  cp "linux-install/assets/gnome/$f.js" "/tmp/opencode/nodecheck/$f.mjs"
  node --check "/tmp/opencode/nodecheck/$f.mjs"
done
```
Expected: all exit 0, no output (py_compile leaves `__pycache__` under `assets/` — delete it: `rm -rf linux-install/assets/__pycache__`).

- [ ] **Step 5: Retarget `test_tray_model.py` and run it**

Change line 13 to resolve the repo asset from `__file__`. Run:
```bash
python3 linux-install/tests/test_tray_model.py
```
Expected: `OK` (5 tests).

- [ ] **Step 6: Commit**

```bash
git add linux-install/assets linux-install/tests/test_tray_model.py
git commit -m "refactor: seed linux-install/assets from heredocs and deployed sources"
```

---

### Task 2: Lint toolchain and shell assets (both bug fixes)

**Files:**
- Modify: `linux-install/assets/micsource`, `linux-install/assets/micsource-build`, `linux-install/assets/micsource-gui`
- Create (tooling, not committed): `/tmp/opencode/bin/shellcheck`, `/tmp/opencode/bin/shfmt`
- Test: behavioral scripts under `/tmp/opencode/asset-tests/` (throwaway, not committed)

**Interfaces:**
- Consumes: the three shell assets from Task 1.
- Produces: `assets/micsource` defines `info() ok() warn() err() ask() confirm() have_cmd() usage()` (its own, standalone — deployed assets never source `common.sh`); `assets/micsource-build` reads `PROJECT_ROOT` from `${HOME}/.local/share/micsource/project.path` (single line, trailing newline tolerated via `tr -d '\n'`) and errors with `micsource-build: project.path missing — re-run linux-install/install.sh from the project checkout` when absent/empty; both available at `/tmp/opencode/bin/{shellcheck,shfmt}` for every later task.

- [ ] **Step 1: Fetch pinned lint tools**

```bash
mkdir -p /tmp/opencode/bin
# shellcheck v0.10.0: GitHub release tarball shellcheck-v0.10.0.linux.x86_64.tar.xz
# shfmt v3.8.0:       GitHub release asset shfmt_v3.8.0_linux_amd64
```
Verify `/tmp/opencode/bin/shellcheck --version` reports v0.10.0 and `/tmp/opencode/bin/shfmt --version` reports v3.8.0 (adjust arch suffix if `uname -m` is `aarch64`; if a pinned URL 404s, use the latest release and say so in the commit message).

- [ ] **Step 2: Write the failing behavioral tests**

In `/tmp/opencode/asset-tests/`, three cases:

1. **CLI defines the missing helpers** — `grep -q '^warn()' linux-install/assets/micsource && grep -q '^ask()' … && grep -q '^confirm()' …` (currently FAIL: `warn` undefined).
2. **`stop` SIGKILL path survives** — fake `$HOME` with `micsource-monitor.py` present; stub `systemctl` (exit 0); stub `pkill` that logs its args and exits 0 for every invocation (always "alive"); stub `sleep` as `exit 0` so the 10-second grace loop runs instantly. Run `HOME=… PATH=stubs:$PATH bash linux-install/assets/micsource stop`; expect exit 0 and stdout containing `monitor did not exit` — **not** `command not found` (currently FAIL: exit 127).
3. **`install-apk` conflict path survives** — stub `adb`: `get-state`→`device`, `install`→stderr `Failure [INSTALL_FAILED_UPDATE_INCOMPATIBLE]`, exit 1; `uninstall`/`shell`/`forward`→exit 0. Feed `n` on stdin. Run with fake `$HOME` containing a staged APK at `micsource-release.apk`; expect **exit 1** (the CLI's declined path), output containing `Device install skipped`, and no `command not found` (currently FAIL: exit 127).

Run all three, record the failures.

- [ ] **Step 3: Fix `assets/micsource` (bug 1)**

Add `warn()` and `ask()` (and `confirm()`, used nowhere yet but completing the helper set) with the same format strings as install.sh's versions (`[WARN]`/`[?]` prefixes, colors optional — keep them uncolored to match this script's existing plain `info`/`err`).

- [ ] **Step 4: Fix `assets/micsource-build` (bug 2)**

Replace the hardcoded `PROJECT_ROOT="/home/hasan/…"` with: read `${HOME}/.local/share/micsource/project.path` (error as specified in Interfaces when missing/empty), then keep the existing `gradlew` existence check. Add two more test cases: (a) no `project.path` → exit 1 with the `project.path missing` message; (b) `project.path` pointing at a dir without `gradlew` → exit 1 with the existing `project moved?` message. Both must run without invoking gradle (the errors occur before `cd`/`./gradlew`).

- [ ] **Step 5: Run the behavioral tests to green**

Run the four cases from Steps 2 and 4. Expected: all PASS.

- [ ] **Step 6: Lint and format the three shell assets**

```bash
/tmp/opencode/bin/shellcheck linux-install/assets/{micsource,micsource-gui,micsource-build}   # zero warnings
/tmp/opencode/bin/shfmt -d -i 4 linux-install/assets/{micsource,micsource-gui,micsource-build} # no diff
bash -n linux-install/assets/{micsource,micsource-gui,micsource-build}
```
Fix warnings with behavior-preserving edits only (quoting, redirection, word-splitting); `# shellcheck disable=SC####` solely for false positives. If a warning cannot be cleared without changing logic, stop and report.

- [ ] **Step 7: Confirm Python/JS assets untouched and commit**

```bash
diff linux-install/assets/micsource-app.py  ~/.local/share/micsource/micsource-app.py
diff linux-install/assets/micsource-tray.py ~/.local/share/micsource/micsource-tray.py
git add linux-install/assets
git commit -m "fix: repair CLI warn/ask helpers and build-helper PROJECT_ROOT; lint shell assets"
```
Expected: both diffs empty.

---

### Task 3: `common.sh`, uninstaller refactor, sandbox test harness (uninstall cases)

**Files:**
- Create: `linux-install/common.sh`, `linux-install/tests/test_install_sandbox.sh`
- Modify: `linux-install/uninstall.sh` (source `common.sh`, drop duplicated helpers/vars, `--help`, unknown-flag exit 2, add `project.path` marker, fix section-6 header)
- Test: `linux-install/tests/test_install_sandbox.sh`

**Interfaces:**
- Consumes: nothing from later tasks.
- Produces — `common.sh` (sourced, sets no shell options; guard: if executed directly, exit 1 with a message):
  - Functions: `info() ok() warn() err() ask() confirm() have_cmd() refuse_root()`.
  - Variables (exact names): `RED GRN YLW BLU BLD RST` (empty when non-TTY or `NO_COLOR` set), `APP_NAME=micsource`, `INSTALL_DIR` (dirname of `BASH_SOURCE[0]`), `PROJECT_ROOT` (parent of `INSTALL_DIR`), `CONFIG_DIR DATA_DIR APPS_DIR SYSTEMD_USER_DIR ICON_THEME_DIR GNOME_EXT_UUID GNOME_EXT_DIR PULSE_LOCK_CONF AUTOSTART_FILE BIN_LINK ADB_LINK` — same values install.sh defines today (`AUTOSTART_FILE` replaces uninstall's `XDG_AUTOSTART`).
  - `refuse_root` prints the existing root error and `exit 1`.
- Produces — `tests/test_install_sandbox.sh`: runnable as `bash linux-install/tests/test_install_sandbox.sh`; prints one `PASS`/`FAIL` line per case; exits 0 iff all pass, 1 otherwise; shellcheck-clean. Provides reusable helpers: `make_sandbox` (mktemp under `/tmp/opencode/`, fake `HOME`, `stubbin/` with logging stubs — **`adb`**: logs `$*` to `$SANDBOX/stub.log`, `get-state` → prints `offline` + exit 1, any other subcommand → exit 0 (a non-`get-state` line in the log fails Task 4's assertions); **`systemctl`** and **`gnome-extensions`**: log args, exit 0), `assert_file`, `assert_gone`, `assert_contains`, `assert_exit`. Every install/uninstall invocation sets `HOME` and env (`XDG_CURRENT_DESKTOP`, `PATH`) explicitly via `env` — never inherited from the ambient session.

- [ ] **Step 1: Write the failing test cases**

Sandbox-test cases for this task (uninstall runs against a **synthetic fixture** the test builds itself — no install.sh involved yet):

1. `uninstall --help` → exit 0, stdout contains `Usage:`.
2. `uninstall --bogus` → exit 2.
3. Full removal: fixture with unit file, desktop file, hicolor icon, CLI symlink → data-dir CLI, adb symlink → bundle adb, autostart entry, pipewire lock, GNOME ext dir (with `metadata.json`), control socket, `config.ini` in config dir, data dir containing markers (`adb.path`, `apk.path`, `micsource`, `micsource-monitor.py`, `project.path`, …). Feed `y` (and `n` to the adb-bundle question if the bundle dir exists — fixture omits it to keep answers simple). Expect exit 0; every fixture path gone; `stub.log` contains `systemctl` `disable --now micsource.service` and `gnome-extensions` `disable micsource-tile@micsource.local` (pins Review Focus 1).
4. Idempotency: run again on the emptied sandbox → exit 0, no errors.
5. Ownership guards: (a) data dir containing only `foreign.txt` → dir still present; (b) config dir without `config.ini` → dir still present; (c) `~/.local/bin/micsource` symlink pointing elsewhere → symlink still present.

Run: `bash linux-install/tests/test_install_sandbox.sh` → cases 1–2 FAIL (no `--help`/exit-2 yet), 3–5 PASS (current behavior already satisfies them — verify; if case 3's current behavior differs, report before proceeding).

- [ ] **Step 2: Create `common.sh`**

Implement exactly the Interfaces block. Colors: `if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then … else … fi`. Path block copied from install.sh's Configuration section (values unchanged).

- [ ] **Step 3: Refactor `uninstall.sh`**

Source `common.sh` via `SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; . "${SRC_DIR}/common.sh"`; delete its local color/helper/path block (keep script-specific vars: `MONITOR_PATH`, `UNIT_FILE`, `DESKTOP_FILE`, `ICON_FILE`, `CLI_TARGET`, `ADB_BUNDLE_ADB`, `SOCK`, marker list). Add arg parsing: `-h|--help` prints a `Usage: uninstall.sh [--help]` banner and exits 0; unknown → err + usage to stderr, exit 2; no args proceeds. Add `project.path` to `data_dir_is_ours` markers. Rename the `# 6. Remove GNOME extension` header to `# 6. Remove stream routing lock, autostart entry, and GNOME extension`.

- [ ] **Step 4: Lint both files**

```bash
/tmp/opencode/bin/shellcheck linux-install/{common.sh,uninstall.sh,tests/test_install_sandbox.sh}
/tmp/opencode/bin/shfmt -d -i 4 linux-install/{common.sh,uninstall.sh,tests/test_install_sandbox.sh}
bash -n linux-install/{common.sh,uninstall.sh}
```
Expected: clean.

- [ ] **Step 5: Run the sandbox test to green**

`bash linux-install/tests/test_install_sandbox.sh` → all cases PASS.

- [ ] **Step 6: Commit**

```bash
git add linux-install/common.sh linux-install/uninstall.sh linux-install/tests/test_install_sandbox.sh
git commit -m "refactor: share installer helpers via common.sh; harden uninstaller CLI"
```

---

### Task 4: install.sh core rewrite (asset copy model)

**Files:**
- Modify: `linux-install/install.sh` (major: remove all six payload heredocs + the icon heredoc + the GNOME heredocs; source `common.sh`; new `step_assets`; strict args; sanity additions; gnome-from-assets)
- Modify: `linux-install/tests/test_install_sandbox.sh` (add install cases)
- Test: the sandbox test

**Interfaces:**
- Consumes: `common.sh` API (Task 3), `assets/*` (Task 1), test helpers `make_sandbox`/`assert_*` (Task 3).
- Produces — install.sh v2 structure (this task keeps today's behavior for adb/build_env/apk/device/config/desktop/tray/systemd/pipewire steps; hygiene comes in Task 5):
  - Arg parsing: `--with-tray`, `-h|--help` (usage → exit 0), unknown → usage to stderr → exit 2.
  - `step_sanity` order: `refuse_root`; `[[ "$(uname -s)" == Linux ]]` else err+exit 1; `$HOME` set/non-empty else err+exit 1; `command -v python3` else err (`python3 is required … install it and re-run`)+exit 1; then the existing `mkdir -p` list.
  - `step_assets` (runs immediately after sanity): for each of `micsource micsource-gui micsource-build micsource-app.py micsource-tray.py micsource-monitor.py`: assert source `${INSTALL_DIR}/assets/<f>` exists (else err + record failure + return 1), `cp -f` to `${DATA_DIR}/<f>`, `chmod 755` all six; then `printf '%s\n' "${PROJECT_ROOT}" > "${DATA_DIR}/project.path"`.
  - GNOME step installs from `${INSTALL_DIR}/assets/gnome/{extension.js,prefs.js,metadata.json}` into `${GNOME_EXT_DIR}` (mkdir first).
  - Icon: `cp -f "${PROJECT_ROOT}/assets/icon.svg"` → `${DATA_ICON}` and `${ICON_PATH}` (drop the 70-line SVG heredoc; the existing themed-icon fallback stays for the missing-file case).
  - Templates unchanged: `config.ini`, `micsource.desktop`, autostart entry, systemd unit, pipewire lock heredocs.
  - `main()` order: `step_sanity` (bare — immediate exit on failure), then each step called as today with `|| true` recording to be added in Task 5 (for this task keep `|| true` so behavior matches today).

- [ ] **Step 1: Write the failing install test cases**

Add to `test_install_sandbox.sh` (all with `XDG_CURRENT_DESKTOP=GNOME`, stubs in PATH, `printf 'n\nn\n'` fed to stdin):

1. **Happy path:** `bash linux-install/install.sh` in a fresh sandbox → exit 0; assert present: `config.ini` (mode `600`), `micsource.desktop`, `micsource.service`, hicolor icon, `DATA_DIR` payload files all executable (`-x`), `project.path` content == repo root, `~/.local/bin/micsource` → `DATA_DIR/micsource`, GNOME ext `metadata.json`; assert **absent**: `DATA_DIR/gnome`; stdout contains `complete`; stdout contains **no** ESC byte (non-TTY → no colors, pins the NO_COLOR/TTY constraint); `stub.log` adb lines ⊆ `get-state` (Review Focus 2); `stub.log` contains `systemctl` `daemon-reload`.
2. **Sanity python3 preflight:** prepare `/tmp/opencode/emptybin` containing only a symlink to `uname` (`ln -s "$(command -v uname)" /tmp/opencode/emptybin/uname` — the Linux check runs before the python3 check and must succeed to reach it), then `env PATH=/tmp/opencode/emptybin /usr/bin/bash linux-install/install.sh` (absolute bash — `env` resolves `bash` in the new PATH) → exit 1, stderr contains `python3`.
3. **Round trip:** continue in the same sandbox → `bash linux-install/uninstall.sh` (feed `y`) → exit 0, all installed paths gone (overlaps Task 3 case 3, now against a real install).

Run → expect FAIL (install.sh still embeds heredocs; case 1's `project.path`/no-`DATA_DIR/gnome` assertions cannot pass yet).

- [ ] **Step 2: Rewrite install.sh to the v2 structure**

Delete heredoc blocks `__CLIEOF__`, `__APPEOF__`, `__GUIEOF__`, `__TRAYEOF__`, `__BUILDEOF__`, `__MONITOREOF__`, `__ICONEOF__`, `__EXTJSEOF__`, `__PREFSEOF__`, `__METADATAEOF__` and their `cat >`/`chmod` plumbing. Source `common.sh` (same line as uninstall.sh) and delete install.sh's duplicated color/helper/path block (keep script-specific vars: `CONFIG_PATH DATA_ICON ICON_PATH DESKTOP_FILE AUTOSTART_FILE UNIT_FILE CLI_PATH ADB_PATH_FILE APK_PATH_FILE ENV_PATH_FILE BUILD_ENV_DIR ADB_BUNDLE_DIR STAGED_APK ANDROID_PKG DEVICE_SOCKET HOST_SOCKET WITH_TRAY` — note `AUTOSTART_FILE`, `BIN_LINK`, `ADB_LINK`, `GNOME_EXT_*`, `PULSE_LOCK_CONF` now come from `common.sh`). Implement `step_assets`, the v2 `step_sanity`, `step_gnome_extension` from assets, icon copies, and strict args exactly as specified in Interfaces. `step_cli` becomes: symlink handling + PATH warning + `ok "CLI ready. Try: micsource help"` (its payload-writing part moved to `step_assets`).

- [ ] **Step 3: Run the sandbox test to green**

`bash linux-install/tests/test_install_sandbox.sh` → all cases (Task 3's + new) PASS.

- [ ] **Step 4: Lint and format**

```bash
/tmp/opencode/bin/shellcheck linux-install/install.sh    # zero warnings
/tmp/opencode/bin/shfmt -d -i 4 linux-install/install.sh
bash -n linux-install/install.sh
```
Expected: clean (fix warnings behavior-preservingly).

- [ ] **Step 5: Confirm no payload logic changed**

```bash
diff linux-install/assets/micsource-app.py  ~/.local/share/micsource/micsource-app.py
diff linux-install/assets/micsource-tray.py ~/.local/share/micsource/micsource-tray.py
grep -c '__CLIEOF__\|__MONITOREOF__\|__APPEOF__' linux-install/install.sh   # expect 0
```
Expected: two empty diffs, count `0`.

- [ ] **Step 6: Commit**

```bash
git add linux-install/install.sh linux-install/tests/test_install_sandbox.sh
git commit -m "refactor: install.sh copies assets instead of embedding heredocs"
```

---

### Task 5: install.sh hygiene — downloads, desktop detection, honest summary and exit codes

**Files:**
- Modify: `linux-install/install.sh`
- Modify: `linux-install/tests/test_install_sandbox.sh` (failure-path cases)
- Test: the sandbox test

**Interfaces:**
- Consumes: install.sh v2 (Task 4), test helpers (Task 3).
- Produces:
  - `fetch <url> <dest>`: prefers `curl -fL --retry 2 --connect-timeout 15 -o`, falls back to `wget -q --tries=2 -O`; returns non-zero on failure; used by all three download sites (adb bundle, JDK, cmdline-tools).
  - Download scratch: `TMP_DIRS=()` + `cleanup_tmp()` iterating it + `trap cleanup_tmp EXIT`; each download does `d="$(mktemp -d "${DATA_DIR}/.dl.XXXXXX")"`; append to `TMP_DIRS`; explicit per-step cleanup stays where it exists today.
  - `gnome_desktop()`: true iff `case "${XDG_CURRENT_DESKTOP:-}:${GNOME_DESKTOP_SESSION_ID:-}" in *[Gg][Nn][Oo][Mm][Ee]*) ;; *) false ;; esac`. `step_gnome_extension` calls it; false → `info` skip line naming the manual install path, record `skipped`.
  - Summary: `record_step <name> <ok|skipped|failed>` appending to `STEP_RESULTS`; after the last step print `== Summary ==` with one line per step (`ok "name"` / `warn "name (skipped)"` / `err "name (FAILED)"`); exit 1 iff any required step is `failed`.
  - `step_device`: only print `ok "adb forward set: …"` when the `adb forward` command succeeded; otherwise `warn` with the real outcome (still optional → `failed` record, exit unaffected).
  - `step_apk`: skip `cp` when `readlink -f "$apk"` equals `readlink -f "${STAGED_APK}"` (avoids `cp: same file` noise when the staged APK is the only candidate).
  - `step_tray`: replace the stale AppIndicator import probe (the tray is pure D-Bus now) with a `python3 -c 'import gi; gi.require_version("Gio", "2.0")'`-style check whose message names `python3-gi`; keep the GNOME-pill hint.

- [ ] **Step 1: Write the failing failure-path cases**

Add to the sandbox test:

1. **Unknown flag / help:** `bash linux-install/install.sh --bogus` → exit 2; `--help` → exit 0, stdout contains `Usage:`.
2. **Required step fails → exit 1:** pre-create `${HOME}/.config/micsource/config.ini` as a **directory** → run install (stdin `n`s) → exit 1 and combined stdout+stderr contains `config (FAILED)` (the summary line emitted via `err` to stderr).
3. **Optional step skipped → exit 0:** same as happy path (build env declined with `n`) → exit 0, summary contains `skipped` for `build_env`.
4. **Download failure cleans up:** sandbox with NO `adb` on the test's `PATH` (build `PATH` as `stubbin:/usr/bin:/bin` — deliberately excluding `~/.local/bin`, where this machine's adb lives, and with a `curl` stub in `stubbin` that logs and exits 22, shadowing the real curl), answer `y` to the bundle prompt → install still exits 0 (optional step), stdout contains `adb (FAILED)`, and `find "$DATA_DIR" -maxdepth 1 \( -name '.dl.*' -o -name '.platform-tools*' \)` prints nothing (pins `fetch` + `mktemp` + `EXIT` trap).
5. **Non-GNOME desktop:** `XDG_CURRENT_DESKTOP=KDE` run → exit 0, GNOME ext dir absent, summary shows `gnome_ext` skipped.
6. **Forward message honesty (code review, not automated):** confirm `step_device`'s `ok "adb forward set"` is inside the success branch — asserted by reading the diff in Step 4.

Run → expect cases 1–5 to FAIL where behavior doesn't exist yet (1 and 5 fail now: no strict args, unconditional gnome step; 2 fails: exit code is 0 today; 3 may already pass; 4 fails: no `fetch`/trap yet).

- [ ] **Step 2: Implement `fetch`, scratch dirs + trap, `gnome_desktop()`**

As specified in Interfaces; replace the three copy-pasted curl/wget blocks and the `$$`/fixed temp names (`${DATA_DIR}/.platform-tools.$$`, `.tools-tmp.$$`, `.jdk.tar.gz`, `.cmdline-tools.zip`) with `fetch` + `mktemp -d "${DATA_DIR}/.dl.XXXXXX"`.

- [ ] **Step 3: Implement summary/exit policy + the honesty fixes**

`record_step` around every step call (replacing bare `|| true`), the `== Summary ==` block, final exit logic, `step_device` forward branch, `step_apk` same-file guard, `step_tray` probe replacement — all exactly per Interfaces.

- [ ] **Step 4: Run tests to green + lint**

```bash
bash linux-install/tests/test_install_sandbox.sh     # all cases PASS
/tmp/opencode/bin/shellcheck linux-install/install.sh
/tmp/opencode/bin/shfmt -d -i 4 linux-install/install.sh
bash -n linux-install/install.sh
```

- [ ] **Step 5: Commit**

```bash
git add linux-install/install.sh linux-install/tests/test_install_sandbox.sh
git commit -m "fix: installer summary, exit codes, download hygiene, desktop detection"
```

---

### Task 6: Documentation

**Files:**
- Modify: `linux-install/docs/AGENT.md` (Installer flow section; source-of-truth/splice convention; safety checklist; `project.path`; new test)
- Modify: `linux-install/README.md` (only if it describes install.sh internals — currently it does not; check and touch only if needed)
- Modify: `linux-install/docs/superpowers/plans/2026-11-03-pure-dbus-tray.md` (annotate Task 4 as superseded)

**Interfaces:**
- Consumes: the finished behavior of Tasks 1–5.
- Produces: docs consistent with the shipped scripts; no stale "splice"/"heredoc" claims in AGENT.md.

- [ ] **Step 1: Rewrite AGENT.md's installer sections**

Replace the "Installer flow (`install.sh`)" narrative with the asset-copy model (step order, `step_assets`, `project.path`, common.sh, summary/exit codes, gnome detection rule, `fetch`/scratch dirs). Replace every "deployed files are the source of truth / heredocs spliced from them" statement with "assets in-repo are the source of truth; deployed copies are outputs written by install.sh". Extend the safety checklist with: shellcheck/shfmt-clean, python3 preflight, honest exit codes, sandbox-verified (`tests/test_install_sandbox.sh`), no-device-traffic guarantees (stubs). Note the two fixed bugs.

- [ ] **Step 2: Annotate the tray plan's Task 4**

Add a line at the top of Task 4: superseded on 2026-11-07 by `2026-11-07-installer-assets-design.md` — the splice became asset seeding (deployed tray/app copied into `linux-install/assets/`).

- [ ] **Step 3: Grep for stale claims and commit**

```bash
grep -rn "splice" linux-install/docs/AGENT.md          # expect only historical/fixed-context mentions
grep -n "heredoc" linux-install/docs/AGENT.md          # only the "templates stay inline" note
git add linux-install/docs
git commit -m "docs: document asset-based installer; mark tray plan Task 4 superseded"
```

---

### Task 7: Final verification and sanctioned real-HOME run

**Files:**
- Possibly modify: `linux-install/assets/{micsource-app.py,micsource-tray.py}` (only per the drift policy)
- Modify: `~/.local/share/micsource/*` (the sanctioned real install), `~/.local/share/micsource/adb.path` (restored)

**Interfaces:**
- Consumes: everything from Tasks 1–6.
- Produces: a green full suite, drift verified, deployed copies in sync with assets, both bug fixes live.

- [ ] **Step 1: Run the full local suite**

```bash
bash linux-install/tests/test_install_sandbox.sh
python3 linux-install/tests/test_tray_model.py
python3 -m py_compile linux-install/assets/micsource-{app,tray,monitor}.py && rm -rf linux-install/assets/__pycache__
bash -n linux-install/{install.sh,uninstall.sh,common.sh} linux-install/assets/{micsource,micsource-gui,micsource-build}
/tmp/opencode/bin/shellcheck linux-install/{install.sh,uninstall.sh,common.sh,tests/test_install_sandbox.sh} linux-install/assets/{micsource,micsource-gui,micsource-build}
/tmp/opencode/bin/shfmt -d -i 4  linux-install/{install.sh,uninstall.sh,common.sh,tests/test_install_sandbox.sh} linux-install/assets/{micsource,micsource-gui,micsource-build}
for f in extension prefs; do cp "linux-install/assets/gnome/$f.js" "/tmp/opencode/nodecheck/$f.mjs"; node --check "/tmp/opencode/nodecheck/$f.mjs"; done
```
Expected: everything exits 0. Any failure → fix in the owning task's style, re-run, commit.

- [ ] **Step 2: Drift re-diff (deployed vs assets)**

```bash
diff linux-install/assets/micsource-app.py  ~/.local/share/micsource/micsource-app.py
diff linux-install/assets/micsource-tray.py ~/.local/share/micsource/micsource-tray.py
```
Empty → proceed. Non-empty → **re-seed** (copy deployed → assets), re-run Step 1, re-diff; if it drifts again, stop and report (do not chase).

- [ ] **Step 3: Real-HOME run with stubbed adb (no device traffic)**

```bash
mkdir -p /tmp/opencode/realrun-stub
printf '#!/bin/sh\necho "offline" >&2\nexit 1\n' > /tmp/opencode/realrun-stub/adb && chmod +x /tmp/opencode/realrun-stub/adb
ADB_BEFORE="$(cat ~/.local/share/micsource/adb.path)"
PATH="/tmp/opencode/realrun-stub:$PATH" bash linux-install/install.sh </dev/null
```
Notes: only `adb` is stubbed here (systemctl/gnome-extensions must be real for a real install); `</dev/null` makes any unexpected prompt take the default `N` answer; `step_pipewire` restarts `pipewire-pulse` — expected brief audio blip (documented in the spec).

- [ ] **Step 4: Post-run assertions**

```bash
printf '%s\n' "$ADB_BEFORE" > /tmp/opencode/adb.before && printf '%s\n' "$(cat ~/.local/share/micsource/adb.path)" > /tmp/opencode/adb.after
diff /tmp/opencode/adb.before /tmp/opencode/adb.after && rm -f /tmp/opencode/adb.{before,after}   # adb.path restored byte-identical — if not, restore it now
diff linux-install/assets/micsource-app.py  ~/.local/share/micsource/micsource-app.py             # deployed == assets
diff linux-install/assets/micsource-tray.py ~/.local/share/micsource/micsource-tray.py
grep -q 'project.path' ~/.local/share/micsource/micsource-build                                   # bug 2 fix live
grep -q '^warn()' ~/.local/share/micsource/micsource                                              # bug 1 fix live
bash -n ~/.local/share/micsource/{micsource,micsource-gui,micsource-build}
systemctl --user is-active micsource.service                                                       # same state as before the run
micsource status | grep audio_seconds                                                              # if the pipewire restart killed the players and the service was active: micsource stop && micsource start, re-check
```
Expected: all pass. If the service was active before the run and `audio_seconds` is frozen after, restart the service (sanctioned recovery in the spec).

- [ ] **Step 5: Commit any resulting changes**

```bash
git status --short   # expect clean unless Step 2 re-seeded or Step 1 forced fixes
git add -A && git commit -m "chore: final verification and live-install sync"   # only if there are changes
```
