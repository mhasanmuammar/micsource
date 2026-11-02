# MicSource — Agent / Maintainer Technical Reference

This document describes how the Linux host-side installation suite works, for
agents and maintainers who need to modify, extend, or audit it.

## Naming convention

Everything host-side is named **micsource** / **MicSource**:

- Application ID: `micsource`
- Dirs: `~/.config/micsource`, `~/.local/share/micsource`
- Scripts: `micsource-app.py`, `micsource-tray.py`, `micsource-monitor.py`, `micsource-gui` (generated at install time)
- Desktop file: `micsource.desktop`, desktop name "MicSource"
- systemd unit: `micsource.service`
- CLI: `~/.local/share/micsource/micsource`, symlinked to `~/.local/bin/micsource`
- Icons: hicolor `micsource.svg`, tray icon id `micsource`
- GNOME extension UUID: `micsource-tile@micsource.local`
- Control socket: `~/.local/share/micsource/micsource.sock`

Two Android-identifiers intentionally keep the upstream name because they are
baked into the APK; changing them here would break device install/start:

- Android package `fr.dzx.audiosource` (from `app/build.gradle`)
- Device-side abstract socket `audiosource` (created by `RecordThread.java`)

The host forward therefore maps `localabstract:micsource` (host) →
`localabstract:audiosource` (device).

## Repository layout

```
linux-install/
├── install.sh          # full installer (bash); generates the python/bash scripts
├── uninstall.sh        # safe uninstaller (bash) with ownership guards
├── README.md           # installation / usage / uninstallation guide
└── docs/
    ├── USER.md         # end-user guide
    └── AGENT.md        # this file
```

Install-time artifacts (created by `install.sh`, owned by the user):

```
~/.local/share/micsource/
├── micsource                   # CLI dispatcher (generated bash script)
├── micsource-release.apk       # staged APK copy
├── apk.path                    # path to the source APK
├── adb.path                    # adb binary path used
├── micsource-icon.svg          # app icon copy
├── micsource-app.py            # desktop control window (generated)
├── micsource-gui               # launcher wrapper for the window (generated)
├── micsource-tray.py           # tray script (generated)
├── micsource-monitor.py        # monitor script (generated)
└── adb-bundle/                 # platform-tools (only if adb missing on host)
    └── platform-tools/adb
~/.local/bin/micsource                              # symlink -> data-dir CLI
~/.local/share/applications/micsource.desktop       # app drawer launcher
~/.config/micsource/config.ini                      # editable config (mode 600)
~/.config/systemd/user/micsource.service            # systemd user unit
~/.config/pipewire/pipewire-pulse.conf.d/10-micsource-stream-lock.conf
~/.local/share/icons/hicolor/scalable/apps/micsource.svg
~/.config/autostart/micsource-tray.desktop           # tray at login (XDG autostart)
~/.local/share/gnome-shell/extensions/micsource-tile@micsource.local/
```

Note: scripts are generated into `~/.local/share/micsource/`, NOT the repo —
this keeps generated files out of the git tree and makes the desktop entry and
systemd unit independent of where the repo lives.

## How the Android side works

The app (`fr.dzx.audiosource`) is an Android service that:
- Requests `RECORD_AUDIO` and (on Android 13+) `POST_NOTIFICATIONS`.
- Starts a foreground service `RecordService` with a microphone notification.
- `RecordThread` binds a `LocalServerSocket` named `audiosource` (abstract
  namespace) on the device.
- When a client connects, it starts `AudioRecord` (44.1 kHz, mono, PCM 16-bit)
  and writes PCM frames to the socket.
- The host connects to the *host side* of the adb forward (`localabstract:
  micsource`) and plays the PCM stream.

## Installer flow (`install.sh`)

1. `step_sanity` — refuses to run as root; creates config/data/app/systemd dirs.
2. `step_adb` — detects `adb` (PATH or bundled). If missing, prompts to download
   the official Google platform-tools into `~/.local/share/micsource/adb-bundle/`.
   Writes the resolved binary path to `adb.path` in both branches (found / bundle
   installed). After installing the bundle it also symlinks
   `~/.local/bin/adb` → bundled adb (guarded; never replaces an existing
   `~/.local/bin/adb`) so `adb` works in terminals without manual PATH edits;
   when `~/.local/bin` is not on PATH it prints the export line instead.
   Requires `curl`/`wget` + `unzip`; cleans up partial downloads on failure.
3. `step_build_env` — checks for a JDK 17 + Android SDK (system: java +
   ANDROID_HOME/`local.properties`; or the installer-managed portable env in
   `~/.local/share/micsource/build-env/`). If none is complete, offers to
   download and install a portable Temurin JDK 17 + Android cmdline-tools and
   runs `sdkmanager` to fetch platform-tools, `platforms;android-34`,
   `build-tools;34.0.0` (licenses auto-accepted). On success writes
   `build-env.path` (JAVA_HOME/ANDROID_HOME lines, sourced by `micsource-build`
   and `step_apk`). Skipping is non-fatal; a prebuilt APK can be used instead.
4. `step_apk` — locates a prebuilt APK (gradle outputs `app-release.apk`,
   `micsource-release.apk`, `app-debug.apk`, or the staged copy). If none is
   found it calls `env_set_if_portable` (managed JDK/SDK first), then runs
   `./gradlew assembleRelease` when `keystore.properties` exists, or
   `./gradlew assembleDebug` otherwise (signing is optional in
   `app/build.gradle`: without the keystore the automatic debug key signs the
   APK). After the build it rescans the candidate list; stages the copy as
   `~/.local/share/micsource/micsource-release.apk`; writes `apk.path`.
5. `step_device` — checks `adb get-state`; if device is online, installs the
   APK (`adb install -r -t`), launches `fr.dzx.audiosource/.MainActivity`, and
   sets up `adb forward localabstract:micsource localabstract:audiosource`.
6. `step_config` — writes `~/.config/micsource/config.ini` (mode 600), with
   `host_socket_name = micsource` and `device_socket_name = audiosource`.
7. `step_desktop` — installs `micsource.desktop` (app drawer); its `Exec` is
   the `micsource-gui` wrapper, which opens the control window (or sends a
   desktop notification if PyGObject is missing). Also installs the project
   SVG (`assets/icon.svg`) into `~/.local/share/icons/hicolor/scalable/
   apps/micsource.svg`; falls back to the generic `audio-input-microphone`
   themed icon when no SVG exists (a PNG is never copied under an `.svg`
   name); refreshes the desktop database if `update-desktop-database` exists.
8. `step_tray` — generates `micsource-tray.py` (executable) in the data
   dir. Tray is **opt-in**: no autostart entry and no binding prompt by
   default; `--with-tray` restores the old behaviour (autostart + binding
   install offer). Without the flag the step warns when the
   AppIndicator/Ayatana Python binding is missing and points at the app's
   Preferences toggle.
9. `step_systemd` — generates `micsource-monitor.py` and the systemd user unit
   `micsource.service` (WantedBy=graphical-session.target,
   Restart=on-failure). Tries `systemctl --user daemon-reload`.
10. `step_cli` — generates the `micsource` bash dispatcher into the data dir and
   symlinks it to `~/.local/bin/micsource` (guarded: an existing non-MicSource
   file/symlink at that path is never replaced). Warns when `~/.local/bin` is
   missing from PATH. CLI commands: `start` (enable+start the systemd unit, or
   background-launch the monitor without systemd), `stop` (systemd stop +
   best-effort `pkill -f` on the exact monitor path), `status` (queries the
   control socket `micsource.sock` → `device=X forward=Y`, systemd unit state,
   `adb get-state`, `adb forward --list`), `run` (foreground forwarding via the
   monitor's `--run` mode until Ctrl+C), `tray`, `window` (exec `micsource-gui`
   — opens the control window), `build-apk` (exec `micsource-build` — build +
   stage the APK), `install-apk` (reinstall the staged APK +
   `am start` + forward), `config` (`xdg-open`), `help`. `step_cli` also
   generates `micsource-app.py` (the Gtk 4 + libadwaita control window; the
   launcher's Exec target), the `micsource-gui` wrapper (bash; notifies
   instead of failing silently when the GUI stack is missing), and
   `micsource-build` (bash; build+stage with the managed JDK/SDK).
11. `step_gnome_extension` — optional; writes `metadata.json`, `extension.js`,
   `prefs.js` under
   `~/.local/share/gnome-shell/extensions/micsource-tile@micsource.local/`.
   Targets GNOME Shell 47+ (ES-module API, installer version 6) — a
   **quick settings pill** (GSConnect-style `QuickMenuToggle`) instead of
   the older `PanelMenu.Button` icon:
   - `MicSourceToggle` extends `QuickSettings.QuickMenuToggle`
     (`GObject.registerClass`, default-export `Extension` subclass —
     above notes on export form and registerClass still apply). The pill
     shows a live subtitle ("Service — off", the phone's model name while
     streaming, "Disconnected", "starting…") and the mic icon
     (`audio-input-microphone-symbolic`; state is conveyed by the
     subtitle + the checked accent colour).
   - Pill click toggles the background service through the CLI
     (`micsource start/stop` — same code path as every other surface,
     async `Gio.Subprocess`), followed by a fast 1.2 s re-poll
     (`_refreshNext`) so `checked` reflects reality quickly. The pill
     uses `toggleMode: false`: `checked` is set only from the polled
     service state and gives the `.quick-toggle:checked` accent colour,
     so a failed click never briefly lies. Icon is the same aligned
     `audio-input-microphone-symbolic` in both states (the -muted
     variant's x-badge visually misaligns the pill); state is conveyed
     by the subtitle + accent colour. Breadcrumb
     `log('MicSource: pill click -> service …')` aids journal debugging.
   - The chevron expands the menu (HIG quick-settings pattern): header
     (`menu.setHeader`) + two non-reactive status rows mirroring the
     control window (**Device**: phone model name when known, else
     connected/disconnected, **Monitoring**: on — streaming / on — waiting /
     starting… / off) + actions (Start/Stop Service, Open Control Window).
   - Status source: the micsource CLI `status` output is parsed
     (`monitor: device=… name=…`, `systemd unit: …`,
     `adb device state: …`) via an async subprocess every 4 s — no shell
     main-loop blocking. The `name=` value feeds the pill subtitle and the
     menu Device row.
   - Status polling calls `communicate_utf8_async(null, cancellable, cb)`
     — GJS wants stdin data FIRST; a `(cancellable, cb)` call crashes
     every poll and freezes the pill on its fallback state ("off")
     even though clicks work (verified via the journal on Shell 51).
   - The pill subtitle label gets an inline `text-align: left;
     padding-left: 0` pin so title and subtitle share the left edge
     across shell point releases/themes (user-observed indent). The
     label belongs to the *inner* `QuickToggle` — since GNOME 45
     `QuickMenuToggle` wraps one instead of subclassing it, and there
     is no `this._subtitle` on the toggle itself (a direct access
     crashed `_init` on Shell 51 with "can't access property
     'set_style', this._subtitle is undefined"). Resolve it via
     `this._box?.get_first_child()?._subtitle` and only ever touch it
     with optional chaining (`?.set_style`), so a future shell
     re-layout degrades to skipping the pin instead of killing `_init`.
   - Registered with
     `Main.panel.statusArea.quickSettings.addExternalIndicator(indicator)`
     — the older `Main.panel.addToStatusArea()` throws "Status indicator
     must be an instance of PanelMenu.Button" for
     `QuickSettings.SystemIndicator` on modern shells (observed on 51;
     API exists since 47, metadata shell-version starts at 47). Pill
     icons use the `iconName` string property and `menu.setHeader`
     also takes an icon name string (NOT `Gio.ThemedIcon` objects).
   - Removed `PanelMenu.Button`-based indicator entirely (no separate
     top-bar icon; the pill lives in the quick settings grid). Shell
     re-imports the module when the extension is disabled/re-enabled
     (app Preferences → GNOME tile toggle, or log out/in).

Re-running install.sh is safe: it regenerates the scripts but **preserves an
existing `~/.config/micsource/config.ini`** (delete that file to regenerate
from scratch).

## Control window (`micsource-app.py`) and launcher wrapper (`micsource-gui`)

Launched by the app drawer (via `micsource-gui`), by `micsource window`, or
from the tray menu's "Open Control Window".

- `micsource-app.py`: Python 3, PyGObject (**Gtk 4 + libadwaita**):
  `Adw.Application` (`application_id=local.micsource`, **NON_UNIQUE
  flags**: every launch is its own primary instance — the default unique
  behavior hands activation to whatever stale or crashed instance still
  holds the bus name, and the new process exits silently without a
  window) hosting an `Adw.ApplicationWindow` (`Adw.ToolbarView` +
  `Adw.HeaderBar`). Main content:
  - **Status** group (`Adw.PreferencesGroup` of HIG property rows): only
    **Device** (connected/disconnected) and **Monitoring**; a hidden
    error row appears only when a poll fails. The service row was
    removed — the systemd unit is an implementation detail.
  - **Input level bar**: a `Gtk.ProgressBar` suffix inside the
    **Monitoring** row (`set_size_request(240, -1)`), fed by the
    monitor's `level` control-socket command, polled by a
    0.3 s thread started at activate (`_meter_loop` → `set_fraction`
    via `GLib.idle_add`); the app polls only while the window is open
    (`close-request` clears the flag). An earlier version used a
    `Gtk.DrawingArea` + Snapshot/Graphene custom segment renderer; it
    was replaced because boxed-type positional args crash PyGObject
    and a hand-drawn bar duplicates native widget functionality.
  - Adaptive window: content wrapped in `Adw.Clamp(maximum_size=600)`
    inside a vertical `Gtk.ScrolledWindow` (`ToolbarView` content) —
    the single column stays centered and readable and the window
    works at any height (HIG adaptive); default 420×540.
  - Service controls: one homogeneous horizontal box (equal-width
    Start/Stop buttons, `suggested-action`/`destructive-action`).
  - **Device** group: HIG boxed-list rows with flat suffix buttons
    (`_action_row_button`: `Adw.ActionRow` + flat `Gtk.Button`
    suffix + `set_activatable_widget`; the row click shares the
    button's busy-guard): Install APK on the Phone, Build APK from
    Source, Open Config Folder.
  - Activity log `Gtk.Frame` + read-only `Gtk.TextView`.
  Errors shown via `Adw.MessageDialog` (GTK4 removed
  `GtkDialog.run()`). The header bar carries a primary menu
  (`open-menu-symbolic` MenuButton → Gio.Menu `app.preferences` /
  `app.about`).
- Preferences dialog (`_open_preferences()`): `Adw.PreferencesDialog`
  when libadwaita >= 1.5 (`Adw.PreferencesWindow` fallback, transient for
  the main window), search enabled; pages **Startup & Panel** and
  **Audio** built from `Adw.PreferencesGroup` + HIG switch rows
  (`_make_switch_row()` prefers `Adw.SwitchRow`, falls back to
  `Adw.ActionRow` + `Gtk.Switch`). Each `Adw.PreferencesPage` sets
  `title=` and `icon_name=` ("applications-system-symbolic" /
  "audio-input-microphone-symbolic") *on the page*: the dialog renders
  one header switcher tab per page from the page's own properties, and
  a page added without them shows blank/broken-image tabs
  (user-reported glitch). Instant apply, no Save button:
  each toggle runs its command off the main thread
  (`_run_toggle()` → `GLib.idle_add` back), toasts via
  `Adw.Toast` + `add_toast()` (logged as fallback). Toggle state
  machine (all switches), built after a user report of inverted
  applies, a lying switch and a dead switch:
  - Clicks are read through a **one-tick-deferred fresh
    `get_active()`** (`_begin_toggle()` → `GLib.idle_add` →
    `_deferred_toggle()`), not synchronously inside the triggering
    signal: some libadwaita versions emit the row's `activated`
    *before* the internal switch commits, so a synchronous read there
    returned the pre-click state and every tap applied the inverse of
    the click (toast said "Setting turned **on**" while switching off,
    and enabled the tile instead).
  - **Two click sources** — `notify::active` on the watch actor (row
    for `Adw.SwitchRow`, embedded `Gtk.Switch` for the fallback) plus
    row `activated` as a belt-and-braces fallback — both funnel into
    `_begin_toggle()`; an in-flight lock (`_toggle_inflight`) makes the
    duplicate harmless and swallows extra activations while an apply
    is running.
  - Programmatic writes (getter init, post-apply sync) **block the
    notify handler** during `set_active()` (`handler_block_by_func`) —
    a one-shot "consume next notify" flag latched forever when the
    value already matched the switch (no notify fires then), silently
    eating the user's next real click (second user report).
  - The worker runs the getter *after* the command and
    `_toggle_done()` sets the switch to the **verified** state — a
    click the shell accepted without honouring can never leave a
    lying switch. Toast text and the Activity-log line
    (`setting applied/FAILED: … (state now: on|off)`) describe the
    verified state.
  - The tile toggle additionally polls `gnome-extensions info` for up
    to ~3 s after the command (one nudge retry) before claiming
    success, because rc=0 only means the user-state change was
    accepted.
  Rows: Auto-start Service (systemctl
  user enable/disable, sensitive only when the unit exists),
  GNOME Top-bar Tile (`gnome-extensions enable/disable
  micsource-tile@micsource.local`; getter maps **only
  `State: ACTIVE*` to on** — `INACTIVE` (what GNOME 45+ prints after a
  disable), `DISABLED`, `ERROR`, `OUT OF DATE`, `UNINSTALLED`,
  `INITIALIZED` are all off; the old point-blacklist missed `INACTIVE`
  and reported a *hidden* tile as on, which desynced the switch and
  failed every verified re-sync — root cause of the "toggle does
  nothing / hides nothing" reports),
  Tray Icon (opt-in: writes/removes the autostart desktop entry and
  spawns/kills `micsource tray`), Virtual Microphone + Play-to-Speakers
  (config `[audio]` section helpers `_cfg_bool`/`_cfg_set_bool`,
  applied at next service start). Unavailable rows become **insensitive**
  with the reason appended to the subtitle (HIG).
- About: `Adw.AboutDialog` (libadwaita >= 1.2) with a MessageDialog
  fallback. Status rows use the `property` style class (HIG property
  rows). The tray stays Gtk 3: the AppIndicator and
  AyatanaAppIndicator client bindings are Gtk 3 only.
- `Gtk.Application` (`application_id=local.micsource`), one `ApplicationWindow`.
- Status block refreshed every 3 s in a background thread: device online +
  forward state (adb), systemd unit state, and the monitor's control-socket
  status (`_query_monitor()` → `status` → `device=X forward=Y
  audio_seconds=N [name=<model>]`; recv buffer 256 bytes so `name=` is not
  truncated), applied with `GLib.idle_add` (adb/socket never ran on the Gtk
  main thread). The **Device** row prefers the monitor's already-resolved
  `name=` (regex `name=([^\n\r]+)` — the model string may contain spaces);
  that chain probes `ro.product.marketname` first, so it shows user-facing
  names like "Redmi A5" instead of the raw `ro.product.model` code
  ("25028RN03A"), and the monitor's per-serial cache keeps probing to
  one-per-connect. Only while the monitor is not running (no `name=` in the
  answer) does the app do its own `adb shell getprop` — again marketname
  first, then model. It shows the model name when connected and known, else
  connected/disconnected; the error row
  is visible only while a poll error is present.
- The window **cannot stream audio itself**; it is a status + control surface
  only. The background service is the single audio pump (the phone serves one
  client at a time, so two pumps would fight over the client slot).
- Buttons: the Start/Stop pair (`systemctl --user`), and the Device group
  rows (Install APK runs the CLI's `install-apk` asynchronously; Build APK
  runs `micsource-build` (Gradle via the managed JDK/SDK), then, on success,
  automatically runs `install-apk`; each phase notifies). Start/Stop are
  enabled/disabled from the polled service state.
- Monitoring row text: `on — phone audio is streaming` (monitor answers and
  the device is connected), `on — waiting for the phone` (monitor answers,
  device away), `starting…` (service active, monitor not yet up), `off`.
  The `audio_seconds` counter still exists in the CLI `status` output for
  debugging but is intentionally not shown in the window.
- Crash logging: `_log_crash()` appends tracebacks to
  `~/.local/share/micsource/gui.log`; `main()` wraps `run()` and
  `_install_excepthook()` captures exceptions raised inside GLib callbacks
  (which PyGObject would otherwise print only to stderr, invisible from the
  app drawer).
- Desktop notifications: `Gio.Notification` via `send_notification` with a
  `notify-send` fallback. Connection/disconnect transitions are announced
  (the first status check is silent).
- Activity log: `Gtk.TextView` (read-only) appended on the main thread.
- `micsource-gui` (bash, the `.desktop` `Exec`): verifies `micsource-app.py`
  exists and that Python can require **Gtk 4.0 + Adw 1** (introspection
  check); otherwise it sends a `notify-send` error naming the missing stack
  (e.g. `python3-gi gir1.2-gtk-4.0 gir1.2-adw-1`) and exits 1 — so a
  broken install never fails silently. When the app itself fails to start
  (no terminal attached — app drawer launch), the wrapper runs it
  supervised: output is appended to `~/.local/share/micsource/gui.log`,
  a notification points to that file, and the same text goes to stderr.
  From an interactive terminal the wrapper `exec`s the app directly
  (full passthrough).

## Build environment (`build-env/`) and build helper (`micsource-build`)

- `step_build_env` installs, on request, a portable JDK 17 (Temurin tarball)
  and Android cmdline-tools into `~/.local/share/micsource/build-env/`
  (`jdk/`, `android-sdk/`), runs `sdkmanager` for platform-tools,
  `platforms;android-34`, `build-tools;34.0.0`, and writes
  `build-env.path` (sourced shell fragment with `JAVA_HOME`/`ANDROID_HOME`).
  It also writes `sdk.dir` into the project's `local.properties` (only when
  absent). A system JDK/SDK takes precedence when already configured.
- `micsource-build` (generated, project root baked in) sources `build-env.path`,
  picks `assembleRelease` with `keystore.properties` / `assembleDebug`
  otherwise, runs `./gradlew` `--no-daemon`, then stages the first found output
  APK to `micsource-release.apk` and writes `apk.path`.
- Uninstaller data-dir markers include `build-env.path`; uninstalling removes
  the whole `build-env/` tree (JDK + SDK, ~1.5 GB) with the data dir.

## Tray script (`micsource-tray.py`)

- Python 3, PyGObject (Gtk 3.0, with AppIndicator3 or AyatanaAppIndicator3
  0.1 aliased to `AppIndicator3`).
- If `AppIndicator3` (or PyGObject) cannot be imported, the tray **logs the
  missing-binding error to `~/.local/share/micsource/tray.log` and exits
  1**. It used to `os.execvp` into `micsource-app.py` "as a fallback" —
  that literally spawned an extra control window on every tray toggle
  (user report), so an explicit tray launch must never silently become a
  different program. The app's toggle now preflights the bindings instead
  (see below).
- Icon: `micsource` (installed SVG) with fallback `audio-input-microphone`.
- Tray script stays on Gtk 3 and tries `AppIndicator3` first, falling back
  to `AyatanaAppIndicator3` aliased as `AppIndicator3` (identical API).
  The tray is **opt-in**: `install.sh --with-tray` keeps the old behaviour
  (install-time binding offer + XDG autostart entry at
  `~/.config/autostart/micsource-tray.desktop`). Otherwise the control
  window's Preferences toggle (Startup & Panel → Tray Icon)
  - prefights the bindings in a **subprocess** (`_tray_bindings_ok()` —
    `Gtk 3.0` + AppIndicator/Ayatana import; Gtk 3 is never imported into
    the app's own Gtk 4 process) and fails with the exact packages
    (`gir1.2-gtk-3.0` + `gir1.2-ayatanaappindicator3-0.1`) when missing,
  - adds a `_tray_display_hint()` warning when the desktop is GNOME
    without the `appindicatorsupport@rgcjonas.gmail.com` extension
    (GNOME has no native StatusNotifier area — without that extension
    the icon is invisible even when the tray process runs fine),
  - then writes/removes the autostart entry and spawns/kills
    `micsource tray`.
- Menu: Status (read-only), Start Service, Stop Service (both spawn
  `[CLI_PATH, "start"|"stop"]` — `CLI_PATH` = the data-dir CLI, so the CLI's
  systemd/no-systemd logic is reused), Open Control Window (spawns
  `micsource-app.py`), Open Config Folder (plain `xdg-open`), Quit.
  Quitting the tray does not stop the service.
- Status polling runs in a **background thread** (subprocess adb calls are
  never made on the Gtk main thread); results are applied on the Gtk main
  thread via `GLib.idle_add`. The icon shows connected/disconnected only.
- The tray has **no audio pump** — no `_vmic_*`, `_pump` or `paplay` code at
  all; monitoring is the background service's job.
- Reads `adb_path` / `serial` / `host_socket_name` from `config.ini`; falls
  back to `adb.path` then `adb` on PATH.

## CLI dispatcher (`micsource`)

Generated bash script in the data dir, symlinked to `~/.local/bin/micsource`.

Commands: `start`, `stop`, `status`, `run`, `tray`, `window`, `install-apk`,
`config`, `help` (unknown commands exit 2 with usage on stderr).

- `resolve_adb()` precedence: `adb_path` from `config.ini` → `adb.path` file →
  bundled `adb-bundle/platform-tools/adb` → `adb` on PATH.
- `status` queries the control socket (`micsource.sock`) with the same
  `status` protocol as the monitor (`device=X forward=Y audio_seconds=N
  [name=<model>]`, recv buffer 256 bytes so the longer line is not
  truncated), then reports the systemd unit state, `adb get-state`, and
  whether `localabstract:micsource` appears in `adb forward --list`.
- `run` execs `python3 micsource-monitor.py --run`, the monitor's foreground
  forwarding mode (connect → stream to paplay/aplay until Ctrl+C).
- `install-apk` reinstalls the staged APK, launches `MainActivity`, and
  re-establishes the `localabstract:micsource -> localabstract:audiosource`
  forward.

## Monitor service (`micsource-monitor.py`)

- Runs as the user under systemd; no root required.
- Main loop every 5 s: if the device is online, ensure the forward exists,
  call `start_audio()` unconditionally and then `_route_guard()`; when the
  device goes offline, call `stop_audio()` (full teardown of players *and*
  virtual-mic modules, so `phone-mic`/`phone-out` disappear promptly).
- `_route_guard()`: defense against the audio policy re-routing our paplay
  streams. PipeWire (1.6.8) was observed moving the `--device=phone-out`
  stream onto the desktop's default speakers via module-stream-restore /
  WirePlumber, which left `phone-mic` silent (stdin pipe fills, pump drops
  chunks) and leaked the phone audio to the physical speakers — the actual
  cause behind "no voice activity in GNOME Settings / dead volume slider"
  reports. The guard maps each live player PID to its
  `pactl list sink-inputs` entry; if the stream sits on a sink other than
  `phone-out` it repairs the routing with `pactl move-sink-input`
  (logged). Runs every loop tick; belt-and-braces beside the stream lock.
- Player environment (`_PLAYER_ENV`): spawned players get
  `PULSE_PROP` = `media.role=MicSource node.dont-move=true
  node.dont-fallback=true` so the stream keeps its own identity and is
  never re-routed or default-sink-fallbacked (verified honored by
  PipeWire 1.6.8: the props appear on the sink-input).
- Player argv gained `--latency=200`: default pw-cat buffering was ~4 s
  (`pulse.attr.tlength=176400 prebuf=174638`), which made the virtual mic
  go live only long after the service started; with the flag the stream
  runs at 5.3 ms quanta (`tlength=1416 prebuf=946`). Starting the app on the device is rate-limited to once per
  ~30 seconds (previously it spammed `am start` every 5 s while offline).
- **Desktop notifications:** `_notify_transition()` tracks the previous
  `(online, forwarded)` state and runs `notify-send` only when the state
  changes (e.g. "Device connected — forwarding audio." / "Device
  disconnected."). The first check after startup is silent; notifications are
  best-effort and never crash the monitor.
- **The monitor is the only owner of the audio pump.** It keeps the
  `_vmic_*` helpers, the `paplay` children and the pump thread; the app
  window and tray were fully stripped of any streaming code. With the
  default config it spawns exactly one `paplay --device=phone-out` child
  (the virtual-mic chain); a second plain `paplay` (speakers) appears only
  when `play_to_speakers = true`. There is no pause/resume protocol any
  more — earlier revisions let the window/tray pause the monitor while they
  streamed "for testing"; that whole path is removed.
- Audio playback (plain `paplay`; the old `aplay`/`pactl play -` fallbacks
  were removed): `pw-cat` needs **no** stdin-file token (`-` breaks it);
  player stdin is set `O_NONBLOCK` and the pump drops chunks on full pipes.
- Known PipeWire quirk: capturing directly from `phone-out.monitor` with
  `parecord` may deliver zeros even while the chain is healthy — the
  remap-source consumes the sink node internally. `phone-mic` itself is
  the ground truth for testing (apps and meters read it, not the sink
  monitor).
- Exposes a control Unix socket at `~/.local/share/micsource/micsource.sock`
  (mode 600) accepting commands: `status` → `device=1 forward=1
  audio_seconds=N name=<model>` (N = seconds of phone audio received, live
  byte counter `_pcm_bytes / 88200` rounded down; the `name=` field is
  appended only while the device is online and the model is known);
  `level` → smoothed input level `0.000–1.000` for the app's visualizer
  (see below); `restart`. Socket
  creation/unlink failures are caught and logged instead of crashing, and
  stale sockets are removed both at startup and shutdown.
- Device-name reporting (for the pill subtitle and the app's Device row):
  `device_name()` probes `ro.product.marketname` → `ro.product.model` →
  `ro.product.vendor.model` → `ro.product.brand` via `adb shell getprop`
  (marketname is the human model string on Pixel-type devices; other
  devices skip straight to model). Results are cached per serial in a
  `STATE` dict and the cache is reset when a new serial is seen, so a
  reconnect re-probes; an empty result is not cached. One probe per
  connect, not per status query.
- Live level metering (for the control window's visualizer): `_update_level()`
  folds each pumped s16le chunk (array + math, dBFS −60…−15 → 0..1) with a
  fast-attack/slow-release EMA (0.45/0.15) under `_level_lock`;
  `_current_level()` decays the value after 0.5 s idle, so the meter falls
  toward zero when the phone stops streaming. Called from the pump loop
  right after `_pcm_bytes += len(data)`.
- `--run` foreground mode (used by the CLI's `micsource run`): sets up the
  forward, spawns the pump/player, and streams until Ctrl+C; skips the
  control socket and monitor loop entirely.

## Config file (`config.ini`)

INI format with sections `[general]`, `[adb]`, `[device]`, `[socket]`,
`[audio]`. Keys: `app_name`, `android_package`, `adb_path`, `serial`,
`host_socket_name` (default `micsource`), `device_socket_name` (default
`audiosource`), `backend`, `[audio] play_to_speakers` (default `false` —
no speaker playback unless the user opts in), `[audio] virtual_mic`
(default `true`). Mode 600 (user-readable only). Parsed
with `configparser` in all three scripts; booleans are read with the
`_cfg_bool()` helper (accepts `true/false/yes/no/1/0/off`, missing keys fall
back to the default).

## Virtual microphone (`phone-mic`)

Owned by the monitor only (the sole pump; `_vmic_*` helpers exist in
`micsource-monitor.py` — the app/tray copies were removed):

- **Design:** PipeWire's PulseAudio compat layer registers `module-pipe-source`
  but never reads the FIFO (the source stays silent — verified: captures from
  it deliver pure zeros), so the classic FIFO recipe does not work on
  PipeWire. Instead the virtual source is built from a `module-null-sink`
  (`phone-out`, desc `MicSource-phone-sink`) **plus** `module-remap-source`
  (`master=phone-out.monitor` → source `phone-mic`, desc
  `MicSource-phone-mic`). The pump plays the phone stream into `phone-out`
  with a dedicated `paplay --device=phone-out` child; apps capture from
  `phone-mic` (mono; PipeWire resamples as needed). Verified working
  end-to-end on PipeWire 1.6.8.
- Speaker playback is a separate plain `paplay` child on the default device,
  spawned only when `play_to_speakers = true` (**off by default**). Both children read raw s16le
  44.1 kHz mono PCM on stdin; `pw-cat` needs **no** stdin token (a `-` file
  argument breaks it — plain stdin works natively). Children spawn with
  `stdin=PIPE` set `O_NONBLOCK` (`_set_stdin_nonblocking`) and the pump drops
  chunks on full pipes, so a wedged player can never stall the pump.
- `_vmic_start` takes ownership: leftover `phone-out`/`phone-mic` owner
  modules from an earlier run/kill are unloaded first
  (`_vmic_cleanup_leftovers`), then the chain is recreated.
- `_vmic_stop()` (from `stop_audio()`) unloads both modules — the sources
  exist only while monitoring runs. The monitor installs a SIGTERM/SIGINT
  handler (`_catch` in `main()`) so `systemctl stop`, `micsource stop` or a
  manual kill still performs the unload.
- If the remap step fails (e.g. PulseAudio without `module-remap-source`),
  apps can pick "Monitor of MicSource-phone-sink" directly as input.

## Stall recovery

If the forward exists but `_pcm_bytes` does not grow for ~20 s while the
device is online, the monitor force-stops and relaunches the phone app
(`am force-stop` + `am start` in `start_device_service()`; also done by the
installer and `install-apk` after every APK install, because an APK
replacement leaves the previous recording pipeline wedged).

## Uninstaller (`uninstall.sh`)

- Refuses to run as root; stops and disables the `micsource`
  systemd user service (if systemd available).
- Without systemd, best-effort `pkill -f` on the exact monitor script path
  (never a generic name).
- Removes: systemd unit, desktop file, hicolor icon, control socket, GNOME
  extension dir, adb bundle (after confirmation), config dir, data dir.
- **Ownership guards:** `rm -rf` targets are only deleted when they contain
  MicSource's own marker files (`config.ini` for the config dir;
  `adb.path` / `apk.path` / `micsource.sock` / the `micsource` CLI / the
  generated window, tray and monitor scripts / `adb-bundle` for the data dir;
  `metadata.json` for the extension).
  A directory that happens to share the name is warned about and left
  untouched.
- Removes the CLI symlink `~/.local/bin/micsource` only when it points at the
  data-dir CLI; a symlink pointing elsewhere or a regular file there is left
  in place.
- Does NOT touch the Android device, system packages, or a package-manager
  installed adb.
- Idempotent and safe to run multiple times (verified in a sandboxed HOME).

## Portability notes

- `~/.local/bin` is commonly on PATH (most distro default `.profile`); the
  installer detects and warns when it is not, and users may need
  `export PATH="$HOME/.local/bin:$PATH"`.
- Tested on GNOME (X11/Wayland). Tray uses `AppIndicator3`, which works on
  GNOME with AppIndicator support and most other XDG desktops. On GNOME
  without it the tray falls back to opening the control window (GNOME ships
  no native tray area) — the micsource-tile GNOME extension is the top-bar
  alternative there (ES-module, GNOME Shell 47+).
- `systemctl --user` is required for the background service; without it the
  unit file is still installed but not activated.
- `paplay` required for audio; without it the install succeeds but playback
  is disabled (logged). The `aplay` fallback was removed (it cannot target
  the virtual-mic null-sink).
- Abstract Unix sockets (`b"\0name"`) are Linux-specific; this suite targets
  Linux only.
- The GNOME tile extension is an ES-module extension (GNOME Shell 47+,
  quick settings pill, verified on Shell 51); legacy-`imports` extensions (GNOME 40–44) fail on
  modern Shell. GNOME has no native tray without the appindicator extension —
  the tile replaces the tray there.

## Added in this revision

- Device-name display: the monitor probes the phone's model name
  (`ro.product.marketname` → `ro.product.model` → …, cached per serial) and
  reports it as `name=<model>` in the `status` control-socket response; the
  pill subtitle prefers the model name ("Service — off" / model /
  "Disconnected" / "starting…"), the pills' menu Device row and the
  control window's Device row show the model (the app parses `name=` out of
  the monitor answer with a 256-byte recv and only falls back to its own
  marketname/model getprop while the monitor is down), and the CLI status
  passthrough uses a 256-byte recv buffer.
- `micsource` CLI dispatcher (`step_cli`): start/stop/status/run/tray/
  install-apk/config/help, with `~/.local/bin` symlink and PATH detection.
- Monitor gained a `--run` foreground mode backing the CLI's `run` command.
- `install.sh` no longer overwrites an existing `~/.config/micsource/
  config.ini` on re-runs (user edits survive; delete the file to regenerate).

## Audit findings fixed in this revision

The following defects were present in the previous version and are fixed:

1. `micsource-tray.py` `_pump_socket`: two `sock.connect()` calls, the first
   built from a nonsensical expression — the second connect on an
   already-connected socket always raised, so audio could never play. Now a
   single clean `sock.connect(b"\0" + name)`.
2. Broken `pactl play -` fallback (no such subcommand) replaced by
   `aplay -t raw -f S16_LE -r 44100 -c 1 -`.
3. Removed unreliable `--device=@DEFAULT_SINK@` from the `paplay` command.
4. Tray "Install adb" menu item ran `install.sh` through `sys.executable`
   (python) — item removed; config-folder item now uses `xdg-open` (the
   previous `gtk-launch` invocation misused a path argument).
5. GNOME `extension.js`: `GLib.spawn_command_line_async` was given a
   `&&`/`||` shell chain although GLib does not spawn a shell — replaced with
   a sync `is-active` check plus async start/stop. `prefs.js` now imports
   `St`. The panel button uses the proper `Main.panel.addToStatusArea` API
   instead of inserting into `quickSettingsMenu.box`.
6. Tray status polling no longer runs adb subprocesses on the Gtk main
   thread (it could freeze the UI for seconds) — moved to a worker thread.
7. Monitor no longer calls `am start` every 5 s while the device is offline
   (rate-limited to ~30 s).
8. Control socket `os.unlink` is now guarded (try/except) at start and at
   shutdown; socket renamed to `micsource.sock`.
9. `step_desktop` no longer copies a PNG under an `.svg` filename; falls back
   to a themed icon instead.
10. `step_adb` cleans up partial downloads and returns cleanly on curl/wget/
    unzip failure instead of aborting the whole installer mid-way.
11. `step_apk` looks for the real gradle output name (`app-release.apk`). It
    now attempts the build instead of skipping: `assembleRelease` with
    `keystore.properties`, otherwise `assembleDebug` (signing made optional in
    `app/build.gradle`; the debug keystore signs the APK). Warns when the
    Android SDK is unconfigured and prints a clear java/SDK hint on failure.
12. Generated tray/monitor scripts now live in `~/.local/share/micsource/`
    (matching the docs) instead of inside the git repo.
13. `uninstall.sh` gained ownership guards before every `rm -rf` and a
    best-effort monitor kill when systemd is absent.
14. Removed unused helpers (`ICON_SIZE`, `wait_for_enter`, `need_tool`).

## Safety / audit checklist

- [x] Installer refuses to run as root.
- [x] All writes are under `~/.local` and `~/.config` (user space only).
- [x] No system package installation without explicit user confirmation.
- [x] adb bundle download is over HTTPS from `dl.google.com`; checksum not
  pinned (future improvement: verify SHA256).
- [x] Every `rm -rf` in the uninstaller is guarded by an ownership check.
- [x] Config file is mode 600; control socket is mode 600.
- [x] Idempotent install and uninstall (verified in a sandboxed HOME).
- [x] Only changes to the Android device are installing the app package and
  an `adb forward` of our own host socket name.
- [x] No destructive commands found in the current scripts (`rm -f` targets are
  explicit file paths; all `rm -rf` targets are guarded variables, never
  user-controlled).

## Suggested improvements

- Pin and verify the platform-tools SHA256 checksum in `step_adb`.
- Add a `--no-device` install mode for air-gapped builds.
- Add APK signature verification before `adb install`.
- Support non-GNOME desktops via `StatusNotifierItem` (KDE/Pantheon).

- PipeWire >= 1.6 stream policy: the installer writes
  `~/.config/pipewire/pipewire-pulse.conf.d/10-micsource-stream-lock.conf`
  (stream rule: any stream with `target.object = "phone-out"` receives
  `node.dont-move` / `node.dont-fallback`) and best-effort restarts
  `pipewire-pulse` to apply it; the monitor's route guard additionally
  self-repairs routing every ~5 s.