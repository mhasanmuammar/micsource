# MicSource Flatpak Bundle — Design Spec (rev 2)

**Date:** 2026-11-25
**Status:** Rev 2 for approval — no Flatpak implementation yet
**Scope:** A Flathub-compatible Flatpak for the Linux host side of MicSource
(GUI, tray, monitor, audio routing, GNOME Quick Settings extension, USB and
wireless ADB). The Android app remains a separate APK.

> **Rev 2 changes.** The maintainer requires (a) the **minimal** device
> permission, (b) the **GNOME extension must stay**, and (c) **USB must keep
> working**. Rev 1 proposed either `--device=all` or a wireless-only build and
> treated the extension as a host add-on. This revision keeps all three:
> `--device=usb` (not `all`), and the extension is bundled, installed and
> driven over D-Bus. The four decisions at the end are updated accordingly.

## Locked constraints (2026-11-25)

1. **Minimal permissions.** Never request `--device=all`,
   `--filesystem=home`, `--filesystem=host`, or
   `--talk-name=org.freedesktop.Flatpak`. Use the narrowest permission that
   makes each feature work.
2. **The GNOME Quick Settings extension is part of the product.** It must be
   shipped and installed by the bundle, not dropped or left to a separate
   installer.
3. **USB must keep working.** Wired ADB is a first-class transport, not a
   wireless-only fallback.

## Intent / why

MicSource turns an Android phone into a PC microphone. The existing
`linux-install/install.sh` installs a Python/GTK4 control window, a
StatusNotifier tray, a monitor service, a GNOME Shell tile, PipeWire routing
help, and a private `adb` bundle into the user's home directory.

Immutable/atomic distributions (Silverblue, Aeon, Vanilla OS, SteamOS) make
home-directory installers fragile. The 2026-11-03 tray design already chose a
"gradually flatpak-ready codebase"; this is the next phase: package the host
suite as a sandboxed Flatpak that can be submitted to Flathub without losing
USB or the GNOME integration.

## What exists today (and what conflicts)

| Piece | Current mechanism | Flatpak conflict |
|---|---|---|
| Control window | `micsource-app.py`, GTK4 + libadwaita | GApplication ID is `local.micsource`; a sandbox may only own its app ID |
| Tray | `micsource-tray.py`, StatusNotifier over GLib/Gio | Works if the sandbox may talk to the watcher; it registers with its unique bus name, so no extra `own-name` is needed |
| Monitor | `micsource-monitor.py`, started by `systemd --user` | Flatpak cannot install or control systemd user units |
| Audio player | host `paplay` / `pactl` | Not present in the GNOME runtime; must be bundled |
| Virtual mic | `pactl load-module module-null-sink` / `module-remap-source` | Must go through the sandbox PulseAudio socket; needs a spike |
| ADB | host/adb bundle, isolated port 5038 | Cannot execute host binaries; must ship `adb` (or speak ADB directly) |
| USB ADB | host udev + `/dev/bus/usb` | Needs `--device=usb`; `--device=all` is broader than necessary |
| GNOME tile | `gnome-extensions` writes an extension into `~/.local/share` | The Flatpak cannot install Shell extensions without a targeted host-data permission |
| PipeWire lock | writes `~/.config/pipewire/pipewire-pulse.conf.d/…` | No host config writes; `_route_guard()` already self-heals at runtime |
| APK install | Gradle build + `apksigner` + `adb install` | No Android SDK/JDK in the Flatpak; Flathub forbids runtime code downloads |
| Notifications | `notify-send` | Use GNotification / the notification portal |
| Open folder/URL | `xdg-open` | Use `Gio.AppInfo.launch_default_for_uri` (OpenURI portal) |

## Approaches

### A — Self-contained, Flathub-shaped Flatpak with USB and the extension (chosen)

The Flatpak contains the GUI, tray, monitor, a source-built `adb`, the
PulseAudio client tools, and the GNOME extension. The monitor runs as a
supervised child of the app; the freedesktop Background portal provides login
autostart. USB uses `--device=usb`. The app installs its own extension into
`$HOME/.local/share/gnome-shell/extensions` through one targeted permission
and enables it through `org.gnome.Shell.Extensions`. The extension is rewritten
to call the app's D-Bus control interface instead of the host CLI/systemd.

- **Pros:** One artifact; USB and the Quick Settings pill both stay; minimal
  device permission; works on immutable systems; no privileged host bridge.
- **Cons:** Must build `adb` from source; one targeted host-data permission
  for the extension (with a Flathub explanation); first install of the
  extension needs a Shell reload/logout; no systemd user unit.

### B — Strictly no `adb` binary (pure Python ADB)

Speak the ADB protocol directly over TCP, open `localabstract:audiosource` on
the device, and skip `adb forward` and the 5039 server.

- **Pros:** Smallest sandbox; no prebuilt binary.
- **Cons:** Android 11+ Wireless debugging pairing uses TLS + SPAKE2+, which
  `adb` implements and a from-scratch client must reimplement; `adb_shell`
  does not provide pairing or forwards. USB is especially hard because raw
  USB ADB needs the same libusb dance. High risk.

### C — Flatpak GUI + companion host bridge

The Flatpak is a sandboxed GUI that talks to a small host service (installed
by `install.sh`) over a Unix socket. The host service owns `adb`, systemd,
PipeWire modules, the GNOME extension, and APK installation.

- **Pros:** Most Flathub-compliant; USB and systemd work; smallest Flatpak.
- **Cons:** Two install steps, a privileged host component, and a new IPC
  protocol; not a true self-contained bundle.

### D — Host `adb` through `flatpak-spawn --host` (rejected)

DroidDeck and some IDE Flatpaks run the host `adb` via
`--talk-name=org.freedesktop.Flatpak` + `flatpak-spawn --host`. This is a
sandbox escape (arbitrary host command execution) and violates the minimal
permission constraint. Rejected.

**Recommendation:** A. C remains the fallback only if a spike proves that
PulseAudio module loading or the source `adb` build cannot work in the
sandbox.

## Chosen architecture (Approach A)

### Identity and runtime

- App ID: `io.github.mhasanmuammar.MicSource` (GitHub owner; reverse-DNS).
- Runtime: `org.gnome.Platform` **51** (available from Flathub; the local host
  has GNOME Shell 51.1 and Flatpak 1.18.4).
- SDK: `org.gnome.Sdk` 51.
- Command: `micsource-gui` (a small wrapper that sets sandbox paths and
  launches the Python app).
- License: MIT (repo `LICENSE`, upstream © Romain Vimont).
- Architectures: `x86_64` and `aarch64`. `adb` and `pactl`/`paplay` are
  source-built, so no arch-specific binary blob is needed.
- **GApplication ID:** change `local.micsource` to
  `io.github.mhasanmuammar.MicSource`. Flatpak only lets a sandbox own its own
  app ID on the session bus; the extension then has a stable name to call.
  The host install keeps working with the same ID (single-instance behaviour
  is unchanged).

### Process model (no systemd)

- One `GApplication` owns the app. Two modes:
  - `micsource-gui` — show the control window.
  - `micsource-gui --background` — no window; run the monitor and optional
    tray.
- The monitor (`micsource-monitor.py`) is a **supervised child** of the app,
  not a systemd unit. The app restarts it if it exits unexpectedly and stops
  it on Quit. This keeps the "one audio pump" invariant.
- The GUI, CLI and monitor talk over a Unix socket in the sandbox-visible
  `$XDG_RUNTIME_DIR/micsource/control.sock`, not `~/.local/share`.
- The "Service" toggle in the GUI starts/stops the monitor child. Status text
  changes from "systemd unit: active" to "monitor: running".
- Login autostart uses the freedesktop **Background portal**
  (`org.freedesktop.portal.Background.RequestBackground`, `autostart=true`,
  `commandline=micsource-gui --background`). If the portal is unavailable, the
  toggle reports that autostart is unsupported; the app still works when
  launched manually. No XDG autostart file is written from the sandbox.
- The extension's Start/Stop actions call the app's D-Bus control methods
  (below), which drive the same monitor child.

### Dependencies

**Runtime (provided by `org.gnome.Platform` 51):**

- Python 3, PyGObject, GLib/Gio, GTK 4, libadwaita.
- Freedesktop portals (notifications, background, file chooser, OpenURI).

**Bundled at build time:**

| Module | Source | Installed files | Why |
|---|---|---|---|
| `micsource` | this repo, pinned tag/commit | `/app/bin/micsource`, `/app/bin/micsource-gui`, `/app/lib/micsource/*.py`, `/app/share/micsource/gnome/*`, desktop/metainfo/icon | the app and its Shell extension |
| `android-platform-tools` | Debian/Ubuntu `android-platform-tools` source (34.x) or AOSP `packages/modules/adb` | `/app/bin/adb` | ADB client/server, TLS pairing, forwards, USB |
| `pulseaudio` (client only) | upstream `pulseaudio` source, `-Ddaemon=false -Dman=false` | `/app/bin/pactl`, `/app/bin/paplay` | module loading and PCM playback |

No pip packages, no Java, no Android SDK, no `apksigner`, no `curl`/`unzip`
at runtime.

**Host-provided (not dependencies we can bundle):**

- PipeWire or PulseAudio daemon, reachable through `--socket=pulseaudio`.
- A running Android phone with the MicSource APK and USB or Wireless
  debugging.
- For the Quick Settings pill: GNOME Shell 47–51 and a running session. GNOME
  needs a StatusNotifier watcher for the tray (the AppIndicator extension is
  a host prerequisite, not shipped by the Flatpak).
- For USB: a udev/logind policy that lets the logged-in user open
  `/dev/bus/usb/…` (the normal `uaccess` setup on desktop distributions). This
  is a host prerequisite, not a Flatpak permission.

### Permissions (`finish-args`) — minimal profile

| Permission | Needed for | Rationale |
|---|---|---|
| `--share=network` | ADB TCP, mDNS discovery, wireless pairing | ADB is network I/O; no host filesystem needed |
| `--socket=pulseaudio` | phone audio → speakers / virtual mic | connects to the host PipeWire Pulse server |
| `--socket=wayland` | GTK4 window | native Wayland |
| `--socket=fallback-x11` + `--share=ipc` | X11 sessions | Flathub standard; `ipc` is required with `fallback-x11` |
| `--device=dri` | GTK4 rendering | GPU access; software fallback exists |
| `--device=usb` | USB ADB | exposes only `/dev/bus/usb`; requires Flatpak ≥ 1.16 |
| `--require-version=1.16.0` | make `--device=usb` meaningful | Flathub's linter requires this for new device permissions |
| `--filesystem=xdg-data/gnome-shell/extensions` | install/update the bundled GNOME extension | one targeted host directory; the Extension Manager Flatpak uses the same mechanism (`~/.local/share/gnome-shell/extensions`) |
| `--talk-name=org.kde.StatusNotifierWatcher` | tray | exact name; no `org.kde.*` wildcard |
| `--talk-name=org.gnome.Shell.Extensions` | enable/disable the extension | exact name; no `org.gnome.*` wildcard; Extension Manager precedent |

**Why no `--own-name`:** the tray registers with its unique bus name
(`RegisterStatusNotifierItem(:1.x)`), and Flatpak lets an app own its own app
ID by default, so `io.github.mhasanmuammar.MicSource` is available to the
extension without an extra `--own-name`.

**Why no `--device=all`:** `all` exposes every device node in `/dev`, far more
than USB ADB needs. Flathub's linter also rejects
`--device=all` combined with another `--device=` entry as redundant. We use
`--device=usb` only.

**Never request:** `--filesystem=home`, `--filesystem=host`,
`--filesystem=/`, `--talk-name=org.freedesktop.Flatpak`, `--socket=system-bus`,
or any `--talk-name=org.gnome.*` / `org.kde.*` wildcard.

### USB: `--device=usb`, not `all`, not the portal

- `--device=usb` exposes the USB bus (`/dev/bus/usb`) and nothing else. Flatpak
  supports it since 1.15.11; `--require-version=1.16.0` guarantees it is
  honoured.
- Flathub's current linter accepts `--device=usb` when `--require-version` is
  at least `1.16.0` (`finish-args-insufficient-required-flatpak`). The older
  advice to use `--device=all` for compatibility predates that rule; with
  `--require-version=1.16.0` this app simply refuses to install on older
  Flatpak instead of silently getting less access.
- The **USB portal** (`org.freedesktop.portal.Usb`) is not usable here: it
  returns a per-device file descriptor after a user prompt, while `adb`
  expects the raw `/dev/bus/usb` tree and does its own ioctls. Adding portal
  support to `adb` is out of scope.
- If a reviewer insists on the backward-compatible form, the only
  linter-approved pair is `--device-if=all:!has-usb-device` +
  `--device=usb`; that grants `all` on Flatpak < 1.16, which conflicts with
  the minimal-permission rule and is unnecessary given the version floor. Do
  not add it.
- Host prerequisite: if `adb devices` says `no permissions`, the user's udev
  rules are the problem, not Flatpak. Document the standard `uaccess` rule.

### The GNOME Quick Settings extension stays

The extension (UUID `micsource-tile@micsource.local`) is shipped inside the
Flatpak at `/app/share/micsource/gnome/` and installed by the app on request
(first run prompt or Preferences → "GNOME Quick Settings pill").

Installation flow:

1. The app copies `extension.js`, `prefs.js`, and `metadata.json` to
   `$HOME/.local/share/gnome-shell/extensions/micsource-tile@micsource.local/`.
   Use `$HOME`, **not** `$XDG_DATA_HOME`: Flatpak redirects
   `XDG_DATA_HOME` into `~/.var/app/<id>/data`, while the host extension
   directory is mounted at its host path by
   `--filesystem=xdg-data/gnome-shell/extensions`.
2. The app calls `org.gnome.Shell.Extensions.EnableExtension(uuid)` on the
   session bus and checks the result with `ListExtensions`/`GetExtensionInfo`.
3. If the running Shell has not discovered a newly copied extension yet, the
   app reports "log out and back in to finish" and keeps the toggle pending.
   `ReloadExtension` is tried first when the Shell already knows the UUID.
4. Preferences shows the state and offers "Remove pill" (delete the host
   directory and call `DisableExtension`).

The extension is **rewritten to use D-Bus**, because a Flatpak cannot provide
the host `micsource` CLI or `systemctl`:

- No `Gio.Subprocess` calls to `micsource status` or `systemctl`.
- On enable: read `GetStatus()` once, then subscribe to `StatusChanged`.
- Pill click: `Start()` / `Stop()`; menu rows read the same status payload;
  "Open MicSource" calls `ShowWindow()`.
- The host shell is not sandboxed, so it can call the app's well-known name
  directly. No `--talk-name` entry is needed for the extension side.

Compatibility: `metadata.json` keeps `shell-version` 47–51. On an older or
non-GNOME host, the app hides the pill option and explains why; the rest of
the app (window, tray, audio) still works.

### D-Bus control interface

- Bus name: `io.github.mhasanmuammar.MicSource` (the GApplication ID).
- Object: `/io/github/mhasanmuammar/MicSource`
- Interface: `io.github.mhasanmuammar.MicSource.Control`
- Methods:
  - `GetStatus() → a{sv}` — `device`, `monitoring`, `audio_seconds`,
    `dropped_seconds`, `tile_installed`, `tile_enabled`, `autostart`.
  - `Start()`, `Stop()`
  - `ShowWindow()`
  - `InstallTile()`, `RemoveTile()`
  - `SetAutostart(b)`
- Signal: `StatusChanged(a{sv})` — emitted at most once per second while the
  monitor is running.

`GetStatus` and `Start`/`Stop` are the only methods the extension needs. The
CLI and GUI keep using the Unix control socket; the D-Bus interface is a thin
adapter so the sandbox boundary stays small.

### Configuration and XDG layout

All app state lives in the sandbox; the extension directory is the only host
path touched, and only when the user installs the pill.

| Purpose | Path inside the Flatpak | Host mapping |
|---|---|---|
| Config | `$XDG_CONFIG_HOME/micsource/config.ini` | `~/.var/app/<id>/config/micsource/config.ini` |
| Data (ADB keys, staged files) | `$XDG_DATA_HOME/micsource/` | `~/.var/app/<id>/data/micsource/` |
| Logs | `$XDG_STATE_HOME/micsource/{gui,tray,monitor}.log` | `~/.var/app/<id>/.local/state/micsource/` |
| Control socket | `$XDG_RUNTIME_DIR/micsource/control.sock` | sandbox-visible runtime dir |
| Cache | `$XDG_CACHE_HOME/micsource/` | `~/.var/app/<id>/cache/micsource/` |
| ADB home | `$XDG_DATA_HOME/micsource/android/` via `ANDROID_USER_HOME` | keeps adb's RSA keys out of `$HOME` and out of the host `~/.android` |
| ADB server | loopback TCP **5039** | host install keeps 5038; never run both against one phone |
| GNOME extension | `$HOME/.local/share/gnome-shell/extensions/micsource-tile@micsource.local` | explicit `--filesystem` mount; user-initiated |

`config.ini` keeps the current keys, with Flatpak defaults:

```ini
[general]
app_name = micsource
android_package = fr.dzx.audiosource

[adb]
adb_path = /app/bin/adb
server_port = 5039

[device]
serial =

[socket]
host_socket_name = micsource
device_socket_name = audiosource

[audio]
backend = paplay
play_to_speakers = false
virtual_mic = true

[gnome]
tile_auto_install = false
```

Environment set by the wrapper:

```sh
export MICSOURCE_CONFIG_DIR="${XDG_CONFIG_HOME}/micsource"
export MICSOURCE_DATA_DIR="${XDG_DATA_HOME}/micsource"
export MICSOURCE_STATE_DIR="${XDG_STATE_HOME}/micsource"
export MICSOURCE_RUNTIME_DIR="${XDG_RUNTIME_DIR}/micsource"
export ANDROID_USER_HOME="${XDG_DATA_HOME}/micsource/android"
export ADB_SERVER_PORT=5039
exec python3 /app/lib/micsource/micsource-app.py "$@"
```

The Python code must stop hardcoding `~/.local/share/micsource` and
`~/.config/micsource`; a small `paths.py` resolves the XDG variables with the
legacy paths as fallbacks so the existing `install.sh` install keeps working.

### Feature replacements

| Current feature | Flatpak implementation |
|---|---|
| `systemctl --user start/stop/status` | app supervises the monitor child; GUI and extension show monitor state |
| `gnome-extensions enable/disable` | `org.gnome.Shell.Extensions` D-Bus + host extension directory |
| GNOME tile status/start/stop | rewritten extension calls the app's D-Bus control interface |
| `notify-send` | `Gio.Notification` / `GNotification` on the app |
| `xdg-open` config folder | `Gio.AppInfo.launch_default_for_uri` (OpenURI portal) |
| PipeWire stream-lock file | **not written**; `_route_guard()` repairs re-routing at runtime |
| `install-apk` / `build-apk` | **not in the Flatpak**; "Open releases" action, or install a user-selected APK via the FileChooser portal |
| host `adb` discovery | always `/app/bin/adb`; never PATH/host |
| host `paplay`/`pactl` | `/app/bin/paplay`, `/app/bin/pactl` |
| tray autostart | Background portal request; no host `.desktop` write |
| systemd unit | none; Flatpak cannot install one. If a user needs boot-time service, the host installer remains the option |

### Flathub packaging files

Add a `flatpak/` directory:

```text
flatpak/
├── io.github.mhasanmuammar.MicSource.yml       # manifest
├── io.github.mhasanmuammar.MicSource.metainfo.xml
├── io.github.mhasanmuammar.MicSource.desktop
├── io.github.mhasanmuammar.MicSource.svg
├── micsource-gui                               # wrapper (installed to /app/bin)
├── paths.py                                    # XDG resolution
└── README.md                                   # build + submission notes
```

Manifest skeleton:

```yaml
id: io.github.mhasanmuammar.MicSource
runtime: org.gnome.Platform
runtime-version: '51'
sdk: org.gnome.Sdk
command: micsource-gui

finish-args:
  - --share=network
  - --socket=pulseaudio
  - --socket=wayland
  - --socket=fallback-x11
  - --share=ipc
  - --device=dri
  - --device=usb
  - --require-version=1.16.0
  - --filesystem=xdg-data/gnome-shell/extensions
  - --talk-name=org.kde.StatusNotifierWatcher
  - --talk-name=org.gnome.Shell.Extensions

modules:
  - name: adb
    buildsystem: simple
    build-commands: [...]        # see the spike
  - name: pulseaudio-tools
    buildsystem: meson
    config-opts: [-Ddaemon=false, -Dtests=false, -Dman=false]
  - name: micsource
    buildsystem: simple
    build-commands:
      - install -Dm755 micsource-gui /app/bin/micsource-gui
      - install -Dm644 *.py /app/lib/micsource/
      - install -Dm644 gnome/* /app/share/micsource/gnome/
      - install -Dm644 io.github.mhasanmuammar.MicSource.desktop /app/share/applications/
      - install -Dm644 io.github.mhasanmuammar.MicSource.metainfo.xml /app/share/metainfo/
      - install -Dm644 io.github.mhasanmuammar.MicSource.svg /app/share/icons/hicolor/scalable/apps/
```

AppStream metainfo must include: `<id>`, `<name>MicSource</name>`, summary,
description, `metadata_license` (CC0-1.0), `project_license` (MIT), homepage,
bugtracker, `launchable`, developer, releases, at least one **desktop**
screenshot, and OARS content rating. The repository currently has only an
Android notification screenshot (`assets/screenshot.png`, 720×536); a proper
control-window screenshot must be added. The desktop file must use the same
reverse-DNS base name for the file and `Icon=`.

## Flathub checklist

- [ ] App ID matches the repository owner; repository is public and linked.
- [ ] MIT license and `LICENSE` included; metainfo `project_license` matches.
- [ ] Build from pinned sources with SHA-256; no network during build.
- [ ] No prebuilt executables (or an approved exception for `adb`).
- [ ] `flatpak-builder-lint` clean; `appstreamcli validate` clean.
- [ ] `--device=usb` plus `--require-version=1.16.0`; **no** `--device=all`.
- [ ] `--filesystem=xdg-data/gnome-shell/extensions` explained in the PR:
      installing the app's own GNOME extension is the only host write, it is
      user-initiated, and the Flatpak Extension Manager uses the same
      mechanism.
- [ ] `--talk-name=org.gnome.Shell.Extensions` and
      `--talk-name=org.kde.StatusNotifierWatcher` are exact names, not
      wildcards.
- [ ] No `--filesystem=home/host`, no `org.freedesktop.Flatpak` access.
- [ ] Runtime 51; no bundled runtime libraries that the platform provides.
- [ ] Screenshots and release notes present.
- [ ] Tested on Wayland and X11, with PipeWire and PulseAudio.
- [ ] Works with the sandbox on a clean profile (`--fresh`), no host leftovers
      other than the extension the user installed.
- [ ] PR to `flathub/io.github.mhasanmuammar.MicSource` with the permission
      rationale and a note that the Android APK is installed separately.

## Validation plan

1. `flatpak-builder --user --install --force-clean builddir flatpak/…yml` on a
   clean machine/container with network disabled after sources are cached.
2. `flatpak run io.github.mhasanmuammar.MicSource` → window opens, tray appears
   if a watcher exists.
3. **Extension:** Preferences → install pill; verify the files under
   `~/.local/share/gnome-shell/extensions/micsource-tile@micsource.local/`,
   log out/in if needed, then click the pill: it starts/stops the monitor and
   its Device/Monitoring rows match the window. Remove it again and confirm
   the directory is gone.
4. **Wireless:** pair/connect to the phone, `audio_seconds` grows,
   `dropped_seconds` stays near zero, `phone-mic` appears in
   `pactl list sources short`.
5. **USB:** with only `--device=usb`, `adb devices` inside the sandbox sees the
   phone, the APK installs/starts, and audio streams. Confirm no
   `--device=all` is needed and that a phone `no permissions` error is traced
   to host udev, not the sandbox.
6. **Autostart:** enable it, log out/in, confirm the background process starts
   via the portal and the monitor reconnects.
7. **Uninstall:** `flatpak uninstall` leaves no app state outside the sandbox.
   The extension is host data; document that the user should use "Remove pill"
   first, or remove it from the Extensions app.
8. Compare queue telemetry with the host build (same 16 KB budget and drop
   behavior).

## Risks and spikes (do these before writing the manifest)

1. **PulseAudio module loading through the Flatpak socket.**
   `pactl load-module module-null-sink/module-remap-source` must reach the
   host PipeWire server and be permitted. If blocked, the virtual mic cannot
   be created. Fallbacks: native PipeWire via
   `--filesystem=xdg-run/pipewire-0` + `pw-cli`/`pw-loopback`, or Approach C.
2. **`adb` from source.** Building `adb` (AOSP or Debian
   `android-platform-tools`) inside the SDK is the main build risk (protobuf,
   BoringSSL, Go tooling in some forks). Fallback: request a Flathub exception
   for Google's platform-tools with a checksum, or move `adb` to a companion
   host service (Approach C). Do **not** use `flatpak-spawn --host`.
3. **Extension install approval and first-load behaviour.** Copying files into
   `~/.local/share/gnome-shell/extensions` is a host-data subdirectory write;
   Flathub grants this on explanation (`finish-args-unnecessary-xdg-data-subdir-mode-access`),
   but reviewers may ask why. The first install may need a logout/login before
   the Shell loads the new UUID; the UI must say so instead of failing
   silently.
4. **Background portal support.** `RequestBackground` support varies by
   desktop; fallback is manual launch/autostart instructions.
5. **StatusNotifier name.** The tray registers with its unique name, which
   should work; if a watcher insists on a well-known name, add the narrowest
   possible `--own-name`.
6. **Port conflict.** Host install uses 5038; Flatpak uses 5039. Verify no
   cross-talk and document that both installs must not run against one phone.
7. **APK distribution.** Flathub forbids downloading executable code at
   runtime. Recommended: no APK in the Flatpak; "Open releases" + a
   user-selected APK via the portal. A bundled APK needs an explicit policy
   decision.
8. **mDNS in the sandbox.** Verify `adb mdns services` works with
   `--share=network`; if not, require manual `IP:PORT` entry.
9. **Flatpak version floor.** `--device=usb` with `--require-version=1.16.0`
   means users on Flatpak < 1.16 (e.g. Ubuntu 24.04's 1.14) cannot install the
   app. This is the price of the minimal device permission; document it and
   keep the host installer for those systems.
10. **udev access.** `--device=usb` exposes the nodes but does not grant the
    user permission to open them. Desktop `uaccess`/`plugdev` rules are a host
    prerequisite.

## Open decisions (need approval)

1. **USB scope — decided:** use `--device=usb` + `--require-version=1.16.0`,
   never `--device=all`. Confirm this is acceptable for the Flathub
   submission (the current linter allows it; the 2025 forum advice was
   written before the rule existed).
2. **GNOME extension — decided:** ship it in the Flatpak, install it into
   `$HOME/.local/share/gnome-shell/extensions` on user request, and rewrite it
   to D-Bus because the host CLI/systemd no longer exist. Confirm the
   one-time logout/login on first install is acceptable.
3. **ADB:** build `adb` from source (clean, harder) or request a prebuilt
   exception (faster, review risk)? *Recommendation: source first; exception
   only if the spike fails.*
4. **Android APK:** no APK in the Flatpak (open releases / user-selected
   file), or bundle a signed APK? *Recommendation: no APK; Flathub-safe.*
5. **Autostart:** Background portal (XDG/freedesktop) or no autostart in the
   Flatpak? *Recommendation: portal, with a clear fallback message.*

## Acceptance criteria

- The Flatpak builds offline from pinned sources and passes
  `flatpak-builder-lint` and AppStream validation.
- **USB works with `--device=usb` alone**; the manifest contains no
  `--device=all`.
- **The GNOME Quick Settings pill is installed and enabled by the bundle**,
  and its status/start/stop actions work through D-Bus with the app sandboxed.
- A clean-profile install streams phone audio over Wi-Fi, creates `phone-mic`,
  and keeps the latency governor's queue bounded (peak < 16 KB, no persistent
  delay).
- No writes outside the sandbox XDG dirs except the user-initiated
  `~/.local/share/gnome-shell/extensions` install.
- The host `install.sh` install remains unchanged and functional alongside the
  spec; the two installs use different ADB ports.
- Documentation covers XDG paths, permissions, USB udev requirements, the
  extension install/uninstall, APK installation, and Flathub submission.
