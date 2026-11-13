# Installer Audit Remediation — Assets as Source of Truth

**Date:** 2026-11-07
**Status:** approved 2026-11-07; amended 2026-11-13
**Scope:** `linux-install/` (install.sh, uninstall.sh, payloads, tests, docs)

> **Status note (2026-11-13).** Approved on 2026-11-07 and largely shipped as
> written. Amended after the pure-D-Bus tray was reverted: on 2026-11-13 the
> deployed tray/app were rolled back to the AppIndicator versions by user
> decision (the pure-D-Bus tray failed at startup with `'DBusConnection'
> object has no attribute 'own_name'`), and `linux-install/assets/` was
> re-seeded from that rollback. Therefore the premises below that seed the
> tray/app from the deployed **pure-D-Bus** files are superseded; the
> asset-copy model, `common.sh`, `project.path`, honest summary/exit codes,
> and the sandbox test are unchanged. Definition-of-done references to
> `linux-install/tests/test_tray_model.py` are void — that test was deleted
> with the reverted code (commit `67af9c6`).

## Intent / why

An audit of `linux-install/install.sh` (3,464 lines) and `uninstall.sh`
(253 lines) found two outright bugs and a set of standard-practice gaps.
The root cause of both the bugs and the gaps is structural: ~90% of
install.sh is generated program code (Python, shell, JS) embedded in quoted
heredocs, which neither humans nor linters can check, and which has already
drifted from the working copies in `~/.local/share/micsource/`.

### Bugs found (must fix)

1. **Generated CLI calls functions it never defines.** The embedded
   `micsource` CLI defines only `info()` and `err()`, but `service_stop()`
   calls `warn` (SIGKILL path) and `device_install()` calls `warn`/`ask`
   (signature-conflict recovery path). Under `set -euo pipefail` those
   paths die with `warn: command not found` (exit 127) — exactly when the
   user needs them.
2. **Generated `micsource-build` hardcodes
   `PROJECT_ROOT="/home/hasan/Projects/VIBE/micsource"`** — the quoted
   heredoc never expands it, so `micsource build-apk` fails on any other
   machine or clone path.

### Audit findings that are in scope (hygiene)

- Every step in `main()` runs `|| true`: the installer always prints
  "install complete" and exits 0 even if everything failed; no summary of
  what was skipped/failed.
- No upfront check of hard requirements (`python3` is required by the
  monitor, GUI and CLI status but never checked).
- No shellcheck/shfmt anywhere; embedded payloads are unlintable.
- ANSI colors emitted when stdout is not a TTY; no `NO_COLOR`.
- Temp files use `$$`/fixed names; no `EXIT` trap for partial downloads.
- The curl/wget download block is copy-pasted 3× (no `fetch()` helper).
- Unknown flags silently ignored in both scripts; `uninstall.sh` has no
  `--help`.
- Misleading success output (`step_device` prints "adb forward set" even
  when the forward failed).
- `step_gnome_extension` installs unconditionally, on every desktop.
- Duplicated helpers/paths between install.sh and uninstall.sh (the same
  drift class the sibling Shanti project hit — see Dosu note "Shanti Code
  Duplication Boundaries").

## Goals

1. Fix both bugs at the source.
2. Extract every program payload into `linux-install/assets/` as real
   files; install.sh becomes orchestration that copies them. **Assets in
   the repo become the source of truth**, retiring the "edit deployed
   files in `~/.local/share`, splice into heredocs later" workflow (the
   pending Task 4 of `2026-11-03-pure-dbus-tray.md` is absorbed/obsolete).
3. All shell code (both scripts, common.sh, shell assets) passes
   shellcheck with zero warnings and is shfmt-formatted; Python assets
   pass `py_compile` and the existing unit test; JS assets get a
   best-effort syntax check.
4. The hygiene items listed above, with no intended behavior change to
   what gets installed.
5. Shared helpers/paths move to `linux-install/common.sh`, sourced by
   both scripts.
6. Docs (`README.md`, `docs/AGENT.md`, tray plan) updated to match.

## Non-goals / anti-goals

- **No** SHA256 pinning, `--yes` non-interactive mode, or CI workflow —
  explicitly declined for this round (were option C).
- **No** logic changes to the payloads. The tray/app assets are seeded
  byte-identical from the deployed copies; the tray's debug
  instrumentation (timestamps/owned/lost/registered lines, still in active
  use per `.superpowers/sdd/2026-11-03-pure-dbus-tray/progress.md`) ships
  as-is — stripping it is a separate decision.
  **Payload edit policy (my call):** the three *shell* assets (CLI, GUI
  wrapper, build helper) may receive behavior-preserving shellcheck/shfmt
  fixes (quoting, redirection, word-splitting) beyond the two named bug
  fixes — `# shellcheck disable` directives only for genuine false
  positives. The *Python and JS* assets stay byte-identical to their
  sources; all bug fixes live in the shell assets, so the sensitive
  deployed tray/app diff remains exactly the seed diff.
- **No** changes to the Android side, config semantics, unit file, or
  installed file layout.
- Anti-goal: a refactor that makes `./install.sh` stop working from a
  plain checkout (the README flow). There is no `curl | bash` single-file
  usage to preserve.

## Constraints (verified 2026-11-07)

- **Seeding sources.** Diff of heredoc-extracted payload vs deployed file:
  CLI / GUI wrapper / build helper / monitor are **byte-identical**;
  `micsource-app.py` deployed is **+76 lines ahead** (watcher preflight,
  `_wire_toggle` connect-order fix); `micsource-tray.py` deployed is the
  **pure-D-Bus rewrite** (634 changed lines). Therefore: seed
  `micsource-app.py` and `micsource-tray.py` from the **deployed** copies
  (the working source of truth), everything else can be seeded from the
  heredocs (identical anyway). Re-diff against deployed right before
  finishing — the user may still be editing deployed files (tray.log was
  touched today).
- **Icon.** The inline 70-line SVG heredoc is byte-identical to the repo
  root `assets/icon.svg`. Drop the heredoc; copy
  `${PROJECT_ROOT}/assets/icon.svg` (already the documented source in
  AGENT.md and the existing fallback path in `step_desktop`) to both
  `~/.local/share/micsource/micsource-icon.svg` (uninstaller ownership
  marker) and the hicolor icon path.
- **Templates stay inline.** Small heredocs that expand `$VAR`
  (`config.ini`, `micsource.desktop`, XDG autostart entry, systemd unit,
  pipewire lock) remain in install.sh — they are genuinely templated and
  too small to gain from extraction.
- **Sandbox verification only** during development: never run the
  installer against the real `$HOME` or a real device while testing —
  sandbox `$HOME` under `/tmp/opencode/...` plus a stub `adb` early on
  `PATH` (returns "offline" for `get-state`) so `step_device` can never
  touch a phone. One **sanctioned real-HOME run** is part of the final
  verification (see DoD 8).
- **Standalone execution (confirmed by user):** no other session is
  executing `2026-11-03-pure-dbus-tray.md` or editing install.sh /
  deployed files; this work proceeds without coordination, and only
  annotates that plan's Task 4 as superseded.
- **A device is currently connected** to this machine, so the real run
  must not let `step_device` reach it: the run is executed with a stub
  `adb` first on `PATH`, and `adb.path` is restored byte-identical
  afterwards (pre-run value recorded first).
- `linux-install/tests/test_tray_model.py` currently loads the tray from
  the deployed path; retarget it to the asset file.

## Approaches considered

- **A (chosen): assets as source of truth.** Extract payloads to
  `linux-install/assets/`, seed tray/app from deployed copies (absorbs
  tray-plan Task 4), installer copies them, shared helpers to
  `common.sh`. Biggest diff; permanently ends the splice workflow and the
  heredoc-drift class of bug.
- **B: finish Task 4 splice into heredocs first, then split.** Respects
  the active plan but moves every payload twice.
- **C: split now from stale heredocs, let Task 4 splice into assets.**
  Ships known-stale tray code; keeps the deployed-as-truth workflow alive
  inside the new structure. Rejected.

## Design (the how)

### Asset layout

```
linux-install/
├── common.sh                  # colors (TTY/NO_COLOR), info/ok/warn/err/ask,
│                              # confirm, have_cmd, shared path variables,
│                              # refuse-root helper — sourced by both scripts
├── install.sh                 # orchestration only (~600-800 lines)
├── uninstall.sh
├── assets/
│   ├── micsource              # CLI dispatcher (bash)   [fix bug 1 here]
│   ├── micsource-gui          # launcher wrapper (bash)
│   ├── micsource-build        # build helper (bash)     [fix bug 2 here]
│   ├── micsource-app.py       # seeded from deployed
│   ├── micsource-tray.py      # seeded from deployed (pure D-Bus)
│   ├── micsource-monitor.py
│   └── gnome/
│       ├── extension.js
│       ├── prefs.js
│       └── metadata.json
└── (icon comes from ../assets/icon.svg — no copy)
```

### install.sh after the change

1. `set -euo pipefail`; source `common.sh` (resolved via
   `"$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"`).
2. Strict arg parsing: `--with-tray`, `-h/--help`, **unknown flag →
   usage on stderr, exit 2**.
3. `step_sanity`: refuse root; refuse non-Linux (`uname -s`); require
   `$HOME` set and writable; **require `python3`** with a distro hint;
   mkdir the target dirs.
4. `step_assets`: copy the payload files from `assets/` (the six
   top-level files) into `~/.local/share/micsource/`, `chmod +x` the
   shell/Python entry points, verify each source file exists first (fail
   the step loudly if an asset is missing). **`assets/gnome/` is NOT
   copied into the data dir** — `step_gnome_extension` installs
   `extension.js`/`prefs.js`/`metadata.json` straight from the repo
   assets into the GNOME extension dir, preserving the installed file
   layout exactly (no new `DATA_DIR/gnome/`, no new uninstaller
   markers).
5. Write `${DATA_DIR}/project.path` (repo root) — same pattern as
   `adb.path`/`apk.path`/`build-env.path`; `micsource-build` reads it
   instead of hardcoding `PROJECT_ROOT`.
6. Remaining steps as today (adb, build env, apk, device, config,
   desktop, tray, systemd unit, GNOME extension, pipewire), with the
   hygiene fixes: `fetch()` helper replacing the 3× curl/wget blocks;
   `mktemp -d` + `EXIT` trap for download scratch; GNOME extension only
   when a GNOME desktop is detected (`XDG_CURRENT_DESKTOP` contains
   `GNOME`, else info-skip); `step_device` reports the real forward
   result instead of unconditional success.
7. **Honest summary + exit code.** Each step records
   `ok/skipped/failed`; the final report lists them. Required steps
   (`sanity`, `assets`, `config`, `desktop`, `cli`, `systemd`) failing →
   exit 1. Optional steps (`adb`, `build_env`, `apk`, `device`, `tray`,
   `gnome_ext`, `pipewire`) failing/skipping → recorded, exit 0 unless a
   required step failed.

### Bug fixes

1. CLI asset gains `warn()`/`ask()`/`confirm()` (same wording as the
   installer's), restoring the `micsource stop` SIGKILL path and the
   `install-apk` signature-conflict recovery prompt.
2. `micsource-build` resolves `PROJECT_ROOT` from
   `~/.local/share/micsource/project.path`; missing/empty file → clear
   error: "re-run linux-install/install.sh from the project checkout".

### uninstall.sh

- Source `common.sh` (drops its duplicated helper/var block).
- Add `project.path` to the data-dir ownership marker list.
- Fix the section-6 header mislabel (it removes the pipewire lock and
  autostart entry before the extension).
- Gain `-h/--help` and unknown-flag rejection (exit 2).
- Otherwise behavior unchanged: guards, confirmations, idempotency.

### Verification (definition of done)

1. `bash -n` on every shell file.
2. `shellcheck` (official static binary, fetched to `/tmp/opencode/bin`)
   — zero warnings on install.sh, uninstall.sh, common.sh, and the three
   shell assets. `shfmt -d` clean with the repo style (4-space indent).
3. `python3 -m py_compile` on the three Python assets;
   `python3 linux-install/tests/test_tray_model.py` passes (retargeted
   to the asset path).
4. `node --check` (via temp `.mjs` copy) on `extension.js`/`prefs.js`.
5. Byte-identity: `diff` each seeded asset against its deployed source
   **before** editing (seeding) and tray/app again **after** all work
   (drift guard while the user may still be editing deployed files).
   **Failure action (my call):** if the final re-diff shows the deployed
   file moved ahead of the seeded asset, re-seed from deployed and re-run
   the affected verification (deployed is the source of truth, so the
   user's newest edits win); if it drifts again during that re-run, stop
   and report rather than chase a moving target.
6. **Committed sandbox test:** `linux-install/tests/test_install_sandbox.sh`
   (new deliverable, itself shellcheck-clean): fake `$HOME` + stub `adb`
   on `PATH`, scripted `n` answers to prompts → assert expected
   files/dirs/modes appear, summary shows expected skips, exit code 0;
   then run `uninstall.sh` in the sandbox → assert full removal, exit 0;
   run uninstall twice (idempotency); assert a foreign file in the data
   dir prevents deletion (ownership guard). Must pass alongside the
   existing `test_tray_model.py`.
7. `git diff` review: install.sh shrinks to orchestration; no payload
   logic changed beyond the two bug fixes (shell assets:
   behavior-preserving lint fixes only; Python/JS assets byte-identical).
8. **Real-HOME run (user-sanctioned, last step):** record pre-run
   `adb.path` and service state → run `./install.sh` from the checkout
   with a stub `adb` first on `PATH` (zero device traffic; the installer
   is expected to be non-interactive here — answer `n` to any unexpected
   prompt) → restore `adb.path` byte-identical to its pre-run value →
   verify deployed payloads are byte-identical to the assets and the two
   bug fixes are live (`micsource-build` reads `project.path`, the CLI
   defines `warn`/`ask`) → `bash -n` the deployed shell files → confirm
   the service is in its pre-run state. Note: `step_pipewire` restarts
   `pipewire-pulse` (existing behavior — brief audio blip); if the
   monitor's players died with it (`micsource status` shows
   `audio_seconds` frozen), restart the service (`micsource stop &&
   micsource start`).

### Docs

- `linux-install/README.md`: no flow changes; note assets layout if it
  documents install.sh internals.
- `docs/AGENT.md`: rewrite "Installer flow" for the asset-copy model;
  replace the splice/source-of-truth convention with "assets in-repo are
  the source of truth; deployed copies are outputs"; update the safety
  checklist (add: shellcheck-clean, python3 preflight, honest exit
  codes, sandbox-verified); note `project.path` and the new
  `tests/test_install_sandbox.sh`.
- `docs/superpowers/plans/2026-11-03-pure-dbus-tray.md`: annotate Task 4
  as superseded by this refactor (splices become asset seeding).
  Confirmed standalone: no concurrent session to coordinate with.

## Risks

- **Concurrent edits to deployed tray/app** while this lands → mitigated
  by the final re-diff (step 5) and by seeding as late as possible.
- **Behavior regressions in the install flow** → mitigated by sandbox
  verification (step 6) and by keeping payload logic byte-identical.
- **Users who copied only install.sh out of the checkout** → none known;
  README documents the checkout flow only.

## What's left to the builder

Implementation sequencing, task breakdown, and per-task verification —
produced by the planning step after this document is approved.
