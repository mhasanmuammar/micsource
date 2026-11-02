# Design: Pure D-Bus tray (no GTK-3 / AppIndicator bindings)

Date: 2026-11-03
Status: approved (approach A of three, chosen over flatpak-only-tray and
flatpak-full-suite)

## Intent

Make the legacy tray work with **zero host packages** on image-based
(immutable) GNU/Linux systems with no package manager, so that nothing in
the MicSource suite requires `gir1.2-gtk-3.0` or
`gir1.2-ayatanaappindicator3-0.1`. This is the first step toward a
gradually flatpak-ready codebase.

## Why it works

An AppIndicator icon has two halves:

* **Display half** — the shell renders StatusNotifier icons (GNOME via the
  `appindicatorsupport` extension; the user's desktop already does this:
  Discord/Zoom/Spotify icons show up fine).
* **Client half** — the app implements `org.kde.StatusNotifierItem` +
  `com.canonical.dbusmenu` over the session bus.

The missing piece was only the client half, and the two GIR packages were
merely one way of implementing it. GLib/Gio (which the control window
already requires, so it is present wherever the suite works at all) can
implement the same protocol directly.

## Goals

- Rewrite `micsource-tray.py` as a GLib/Gio-only daemon with the same UX:
  status icon (connected/disconnected), menu **Status / Start Service /
  Stop Service / Open Control Window / Open Config Folder / Quit**.
- Registers with `org.kde.StatusNotifierWatcher`, exports
  `org.kde.StatusNotifierItem` (icon name + tooltip) and a
  `com.canonical.dbusmenu` server (GetLayout / GetGroupProperties /
  GetProperty / AboutToShow / Event / EventGroup), pushing updates via
  LayoutUpdated + ItemsPropertiesUpdated + NewToolTip/NewIcon/NewStatus.
- Status polling unchanged: worker thread runs adb subprocesses, applies
  on the main loop via `GLib.idle_add`.
- Re-registers when the watcher restarts (NameOwnerChanged watch).
- With no watcher on the bus: log to `~/.local/share/micsource/tray.log`
  and exit 1 (the prefs toggle reports failure).
- Prefs toggle preflight becomes a D-Bus check ("is a StatusNotifier
  watcher running?") instead of a GIR-binding check.

## Non-goals / anti-goals

- No flatpak of the tray or the suite in this change (a later, gradual
  phase).
- No behavior changes beyond the tray internals: the CLI `tray` command,
  the autostart desktop entry, and the prefs-toggle UX stay identical.
- The control window and monitor are not touched (already
  PyGObject-only).

## Constraints

- Python 3 + PyGObject (GLib/Gio) only — the same host requirement the
  control window already imposes.
- `install.sh --with-tray` loses its binding-package offer (nothing left
  to install); docs updated.
- UX strings in English; no destructive commands; everything host-side
  named `micsource` (Android identifiers stay upstream).

## File structure

- Rewrite: `~/.local/share/micsource/micsource-tray.py` (deployed copy is
  the source of truth; installer heredoc spliced from it, byte-identical).
- Modify: `~/.local/share/micsource/micsource-app.py` (`_apply_tray`
  preflight + messages).
- Modify: `linux-install/install.sh` (`step_tray` text + heredocs).
- Modify docs: `linux-install/README.md`, `docs/USER.md`, `docs/AGENT.md`.
- New tests: `linux-install/tests/test_tray_model.py` (stdlib unittest,
  runs in the sandbox without gi via a fake-`gi` stub).
