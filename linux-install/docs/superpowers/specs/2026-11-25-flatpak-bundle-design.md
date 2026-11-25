# MicSource Flatpak Bundle — Design Spec

**Date:** 2026-11-25
**Status:** Draft for approval — no Flatpak implementation yet
**Scope:** A Flathub-compatible Flatpak for the Linux host side of MicSource
(GUI, tray, monitor, audio routing). The Android app remains a separate APK.

> **Why this is a draft.** The host suite currently relies on four things a
> Flathub sandbox does not allow: a systemd user unit, a GNOME Shell extension,
> host `adb`, and host PipeWire config writes. The spec recommends how to
> replace each one. The four open decisions at the end change the manifest, so
> they need an explicit choice before implementation.

## Intent / why

MicSource turns an Android phone into a PC microphone. The existing
`linux-install/install.sh` installs a Python/GTK4 control window, a
StatusNotifier tray, a monitor service, a GNOME Shell tile, PipeWire routing
help, and a private `adb` bundle into the user's home directory.

Immutable/atomic distributions (Silverblue, Aeon, Vanilla OS, SteamOS) make
home-directory installers fragile. The 2026-11-03 tray design already chose a
"gradually flatpak-ready codebase"; this is the next phase: package the host
suite as a sandboxed Flatpak that can be submitted to Flathub.

## What exists today (and what conflicts)

| Piece | Current mechanism | Flatpak conflict |
|---|---|---|
| Control window | `micsource-app.py`, GTK4 + libadwaita | None — runtime provides the libraries |
| Tray | `micsource-tray.py`, StatusNotifier over GLib/Gio | Needs a watcher name on the filtered bus; no GNOME extension |
| Monitor | `micsource-monitor.py`, started by `systemd --user` | Flatpak cannot install or control systemd user units |
| Audio player | host `paplay` / `pactl` | Not present in the GNOME runtime; must be bundled or replaced |
| Virtual mic | `pactl load-module module-null-sink` / `module-remap-source` | Must go through the sandbox PulseAudio socket; needs a spike |
| ADB | host/adb bundle, isolated port 5038 | Cannot execute host binaries; must ship `adb` or speak ADB directly |
| USB ADB | host udev + `/dev/bus/usb` | Requires a device permission; `--device=usb` is not accepted by Flathub yet |
| GNOME tile | `gnome-extensions` writes an extension into `~/.local/share` | Cannot install Shell extensions from a Flatpak |
| PipeWire lock | writes `~/.config/pipewire/pipewire-pulse.conf.d/…` | No host config writes; the monitor's `_route_guard()` already self-heals |
| APK install | Gradle build + `apksigner` + `adb install` | No Android SDK/JDK in the Flatpak; Flathub forbids download-at-runtime executables |
| Notifications | `notify-send` | Use GNotification / portal instead |
| Open folder/URL | `xdg-open` | Use `Gio.AppInfo.launch_default_for_uri` |

## Goals

- One installable Flatpak (`io.github.mhasanmuammar.MicSource`) for the Linux
  host suite, installable on immutable distributions and submittable to Flathub.
- Keep the measured latency governor and `dropped_seconds` telemetry.
- Keep USB **and** Wireless debugging if Flathub accepts the USB permission;
  otherwise ship a wireless-first manifest and document the limit.
- Use only XDG paths, freedesktop portals, and Flathub-accepted permissions.
- Build every executable from source at build time (no network at build time).
- Make the Flatpak and the existing `install.sh` install mutually exclusive
  (different ADB ports and no shared state).

## Non-goals

- Building the Android APK inside the Flatpak (no Android SDK/JDK).
- Installing a GNOME Shell extension from the Flatpak.
- Writing host systemd units, host PipeWire config, or host autostart files.
- Replacing the `install.sh` flow for users who prefer a home-directory install.
- Changing the audio format (44.1 kHz s16 mono) or the 16 KB latency budget.

## Anti-goals (failure even if it runs)

- Requesting `--filesystem=home`, `--filesystem=host`, or
  `--talk-name=org.freedesktop.Flatpak` (host command execution).
- Downloading `adb`, the APK, or any executable at runtime.
- Shipping a prebuilt `adb` without a documented Flathub exception.
- Silently depending on the host `adb`, host systemd, or a GNOME extension.
- Making the Flatpak and the host install fight over port 5038.

## Approaches

### A — Self-contained, wireless-first Flathub Flatpak (recommended)

The Flatpak contains the GUI, tray, monitor, a source-built `adb`, and the
PulseAudio client tools. The monitor runs as a supervised child of the app; the
desktop portal provides login autostart. USB support is an optional permission
profile. No systemd, no Shell extension, no host config writes.

- **Pros:** One artifact, Flathub-shaped, works on immutable systems; keeps the
  current UX for Wi-Fi users; no privileged host bridge.
- **Cons:** Must build `adb` from source; USB needs `--device=all`; the GNOME
  tile is gone; APK installation becomes "user-supplied file or release page".

### B — Strictly no `adb` binary (pure Python ADB)

Speak the ADB protocol directly over TCP (as `io.github.erenseymen.android-tv-remote`
does with `adb_shell`), open `localabstract:audiosource` on the device, and skip
`adb forward` entirely.

- **Pros:** Smallest sandbox, no prebuilt binary, no 5038 server.
- **Cons:** Android 11+ Wireless debugging pairing uses TLS + SPAKE2+, which
  `adb` implements and a from-scratch client must reimplement; `adb_shell` does
  not provide pairing or forwards. High risk and a large rewrite.

### C — Flatpak GUI + companion host bridge

The Flatpak is a sandboxed GUI that talks to a small host service (installed by
`install.sh`) over a Unix socket. The host service owns `adb`, systemd, PipeWire
modules, the GNOME extension, and APK installation.

- **Pros:** Most Flathub-compliant; USB and systemd work; smallest Flatpak.
- **Cons:** Two install steps, a privileged host component, and a new IPC
  protocol; not a true self-contained bundle; hard to submit as a normal app.

**Recommendation:** A, with C as the fallback for USB/module-loading if a spike
shows they cannot work in the sandbox. B is rejected for now: pairing is the
blocker, and the existing `adb` behavior is already well tested.

## Chosen architecture (Approach A)

### Identity and runtime

- App ID: `io.github.mhasanmuammar.MicSource` (GitHub owner; Flathub requires a
  reverse-DNS ID and a real repository).
- Runtime: `org.gnome.Platform` **51** (available from Flathub; local host is
  GNOME Shell 51.1 with Flatpak 1.18.4).
- SDK: `org.gnome.Sdk` 51.
- Command: `micsource-gui` (a wrapper that sets XDG/env paths and launches the
  Python app).
- License: MIT (repo `LICENSE`, upstream © Romain Vimont).
- Architecture: `x86_64` and `aarch64` (Flathub builds both; no arch-specific
  assets beyond `adb`/`pactl`, which are source-built).

### Process model (no systemd)

- One `GApplication` owns the app. Two modes:
  - `micsource-gui` — show the control window.
  - `micsource-gui --background` — no window; run the monitor + optional tray.
- The monitor (`micsource-monitor.py`) is a **supervised child** of the app,
  not a systemd unit. The app restarts it if it exits unexpectedly, and stops it
  on Quit. This keeps the "one audio pump" invariant.
- The GUI and monitor talk over a Unix socket in the sandbox-private
  `$XDG_RUNTIME_DIR/micsource/control.sock`, not `~/.local/share`.
- The "Service" toggle in the GUI starts/stops the monitor child. Status text
  changes from "systemd unit: active" to "monitor: running".
- Login autostart uses the freedesktop **Background portal**
  (`org.freedesktop.portal.Background.RequestBackground`, `autostart=true`,
  `commandline=micsource-gui --background`). If the portal is unavailable, the
  toggle reports that autostart is unsupported; the app still works when
  launched manually. No XDG autostart file is written from the sandbox.

### Dependencies

**Runtime (provided by `org.gnome.Platform` 51):**

- Python 3, PyGObject, GLib/Gio, GTK 4, libadwaita.
- GStreamer base/good (only if the audio player is reimplemented with it; the
  chosen path bundles `paplay`/`pactl` instead).
- Freedesktop portals (notifications, background, file chooser, OpenURI).

**Bundled at build time:**

| Module | Source | Installed files | Why |
|---|---|---|---|
| `micsource` | this repo, pinned tag/commit | `/app/bin/micsource-gui`, `/app/lib/micsource/*.py`, desktop/metainfo/icon | the app |
| `android-platform-tools` | Debian/Ubuntu `android-platform-tools` source (34.x) or AOSP `packages/modules/adb` | `/app/bin/adb` (+ private libs) | ADB client/server, TLS pairing, forwards |
| `pulseaudio` (client only) | upstream `pulseaudio` source, `-Ddaemon=false` | `/app/bin/pactl`, `/app/bin/paplay` | module loading and PCM playback |

No pip packages, no Java, no Android SDK, no `apksigner`, no `curl`/`unzip` at
runtime.

**Host-provided (not dependencies we can bundle):**

- PipeWire or PulseAudio daemon, reachable through `--socket=pulseaudio`.
- A running Android phone with the MicSource APK and USB/Wireless debugging.
- Optional: a StatusNotifier watcher (GNOME needs the AppIndicator extension,
  which is a host prerequisite, not shipped by the Flatpak).

### Permissions (`finish-args`)

Minimal profile, with the USB decision called out separately:

| Permission | Needed for | Rationale |
|---|---|---|
| `--share=network` | ADB TCP, mDNS discovery, wireless pairing | ADB is network I/O; no host filesystem needed |
| `--socket=pulseaudio` | phone audio → virtual mic / speakers | connects to the host PipeWire Pulse server |
| `--socket=wayland` | GTK4 window | native Wayland |
| `--socket=fallback-x11` + `--share=ipc` | X11 sessions | Flathub standard; requires `--share=ipc` |
| `--device=dri` | GTK4 rendering | GPU access; software fallback exists |
| `--talk-name=org.kde.StatusNotifierWatcher` | tray | exact name, no `org.kde.*` wildcard (linter rejects wildcards) |
| `--own-name=io.github.mhasanmuammar.MicSource.StatusNotifierItem` | tray item | exact app-ID-namespaced name; verify the watcher accepts it |
| `--env=ADB_SERVER_PORT=5039` | avoid clashing with host install | set by the wrapper, not necessarily a manifest arg |

**USB profile (only if USB is in scope):**

- Flathub currently does **not** accept `--device=usb`: it requires Flatpak
  ≥ 1.16 and `--require-version=1.16.0`, but supported distros (e.g. Ubuntu
  24.04) ship older Flatpak; Flathub maintainers recommend `--device=all`.
- Adding `--device=all` grants every device node, not just USB. It must be
  justified in the Flathub PR. If rejected, ship wireless-only and keep USB in
  the host installer (Approach C for that feature).
- `--device=usb` remains documented as the future minimal option once Flathub's
  build infrastructure and supported distros meet the 1.16 floor.

**Never request:** `--filesystem=home`, `--filesystem=host`,
`--filesystem=/`, `--talk-name=org.freedesktop.Flatpak`, `--socket=system-bus`,
`--device=all` without justification, or any `--talk-name=org.gnome.*` /
`org.kde.*` wildcard.

### Configuration and XDG layout

All state lives in the sandbox; no host paths are touched.

| Purpose | Path inside the Flatpak | Host mapping |
|---|---|---|
| Config | `$XDG_CONFIG_HOME/micsource/config.ini` | `~/.var/app/io.github.mhasanmuammar.MicSource/config/micsource/config.ini` |
| Data (ADB keys, staged files) | `$XDG_DATA_HOME/micsource/` | `~/.var/app/<id>/data/micsource/` |
| Logs | `$XDG_STATE_HOME/micsource/{gui,tray,monitor}.log` | `~/.var/app/<id>/.local/state/micsource/` |
| Control socket | `$XDG_RUNTIME_DIR/micsource/control.sock` | sandbox-private runtime dir |
| Cache | `$XDG_CACHE_HOME/micsource/` | `~/.var/app/<id>/cache/micsource/` |
| ADB home | `$XDG_DATA_HOME/micsource/android/` via `ANDROID_USER_HOME` | keeps adb's RSA keys out of `~` and out of the host `~/.android` |
| ADB server | loopback TCP **5039** | host install keeps 5038; never run both against one phone |

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
| `systemctl --user start/stop/status` | app supervises the monitor child; GUI shows monitor state |
| `notify-send` | `Gio.Notification` / `GNotification` on the app |
| `xdg-open` config folder | `Gio.AppInfo.launch_default_for_uri` (OpenURI portal) |
| GNOME tile | **not shipped**; document that the GNOME extension is a host add-on |
| PipeWire stream-lock file | **not written**; `_route_guard()` repairs re-routing at runtime |
| `install-apk` / `build-apk` | **not in the Flatpak**; "Open releases" action, or install a user-selected APK via the FileChooser portal |
| host `adb` discovery | always `/app/bin/adb`; never PATH/host |
| host `paplay`/`pactl` | `/app/bin/paplay`, `/app/bin/pactl` |
| tray autostart | Background portal request; no host `.desktop` write |

### Flathub packaging files

Add a `flatpak/` directory:

```text
flatpak/
├── io.github.mhasanmuammar.MicSource.yml       # manifest
├── io.github.mhasanmuammar.MicSource.metainfo.xml
├── io.github.mhasanmuammar.MicSource.desktop
├── io.github.mhasanmuammar.MicSource.svg
├── micsource-gui                               # wrapper (installed to /app/bin)
└── README.md                                   # build + submission notes
```

Manifest skeleton:

```yaml
app-id: io.github.mhasanmuammar.MicSource
runtime: org.gnome.Platform
runtime-version: "51"
sdk: org.gnome.Sdk
command: micsource-gui

finish-args:
  - --share=network
  - --socket=pulseaudio
  - --socket=wayland
  - --socket=fallback-x11
  - --share=ipc
  - --device=dri
  # USB ADB; omit for the wireless-only profile (see spec).
  - --device=all
  - --talk-name=org.kde.StatusNotifierWatcher
  - --own-name=io.github.mhasanmuammar.MicSource.StatusNotifierItem

modules:
  - name: adb
    buildsystem: simple
    build-commands: [...]
  - name: pulseaudio-tools
    buildsystem: meson
    config-opts: [-Ddaemon=false, -Dtests=false, -Dman=false]
  - name: micsource
    buildsystem: simple
    build-commands:
      - install -Dm755 micsource-gui /app/bin/micsource-gui
      - install -Dm644 *.py /app/lib/micsource/
      - install -Dm644 io.github...desktop /app/share/applications/
      - install -Dm644 io.github...metainfo.xml /app/share/metainfo/
      - install -Dm644 io.github...svg /app/share/icons/hicolor/scalable/apps/
```

AppStream metainfo must include: `<id>`, `<name>MicSource</name>`, summary,
description, `metadata_license` (CC0-1.0), `project_license` (MIT), homepage,
bugtracker, `launchable`, developer, releases, screenshots (Flathub requires at
least one), and OARS content rating. The desktop file must use the same
reverse-DNS base name for the file and `Icon=`.

## Flathub checklist

- [ ] App ID matches the repository owner; repository is public and linked.
- [ ] MIT license and `LICENSE` included; metainfo `project_license` matches.
- [ ] Build from pinned sources with SHA-256; no network during build.
- [ ] No prebuilt executables (or an approved exception for `adb`).
- [ ] `flatpak-builder-lint` clean; `appstreamcli validate` clean.
- [ ] No `--filesystem=home/host`, no host command execution, no wildcard names.
- [ ] `--device=all` justified in the PR, or the wireless-only profile used.
- [ ] Runtime 51; no bundled runtime libraries that the platform provides.
- [ ] Screenshots and release notes present.
- [ ] Tested on Wayland and X11, with PipeWire and PulseAudio.
- [ ] Works with the sandbox on a clean profile (`--fresh`), no host leftovers.
- [ ] PR to `flathub/io.github.mhasanmuammar.MicSource` with the permission
      rationale and a note that the Android APK is installed separately.

## Validation plan

1. `flatpak-builder --user --install --force-clean builddir flatpak/…yml` on a
   clean machine/container with network disabled after sources are cached.
2. `flatpak run io.github.mhasanmuammar.MicSource` → window opens, tray appears
   if a watcher exists.
3. Wireless: pair/connect to the phone, `audio_seconds` grows, `dropped_seconds`
   stays near zero, `phone-mic` appears in `pactl list sources short`.
4. USB: only with the USB profile; `adb devices` sees the phone inside the
   sandbox; install/start the APK; stream.
5. Autostart: enable it, log out/in, confirm the background process starts via
   the portal and the monitor reconnects.
6. Uninstall: `flatpak uninstall` leaves no host files or processes.
7. Compare queue telemetry with the host build (same 16 KB budget and drop
   behavior).

## Risks and spikes (do these before writing the manifest)

1. **PulseAudio module loading through the Flatpak socket.** `pactl load-module
   module-null-sink/module-remap-source` must reach the host PipeWire server and
   be permitted. If blocked, the virtual mic cannot be created. Fallbacks:
   native PipeWire via `--filesystem=xdg-run/pipewire-0` + `pw-cli`/`pw-loopback`,
   or Approach C (host bridge).
2. **`adb` from source.** Building `adb` (AOSP or Debian `android-platform-tools`)
   inside the SDK is the main build risk. Fallback: request a Flathub exception
   for Google's platform-tools with a checksum, or make the Flatpak
   wireless-only and use a companion host `adb`.
3. **USB permission acceptance.** `--device=all` is broad; Flathub may reject
   it. Fallback: wireless-only Flathub manifest, USB in the host installer.
4. **Background portal support.** `RequestBackground` support varies by desktop;
   fallback is manual launch/autostart instructions.
5. **StatusNotifier name.** Confirm the watcher accepts an app-ID-namespaced
   service name; if not, use the exact `org.kde.StatusNotifierItem-<pid>-<id>`
   name and add the narrowest possible `--own-name`.
6. **Port conflict.** Host install uses 5038; Flatpak uses 5039. Verify no
   cross-talk and document that both installs must not run against one phone.
7. **APK distribution.** Flathub forbids downloading executable code at runtime.
   Recommended: no APK in the Flatpak; "Open releases" + user-selected APK via
   the portal. A bundled APK needs an explicit policy decision.
8. **mDNS in the sandbox.** Verify `adb mdns services` works with
   `--share=network`; if not, require manual `IP:PORT` entry.

## Open decisions (need approval)

1. **USB scope:** include `--device=all` (full USB + Wi-Fi, broader permission,
   review risk) or ship wireless-only and keep USB in the host installer?
   *Recommendation: include USB, justify `--device=all`; keep a wireless-only
   variant ready.*
2. **ADB:** build `adb` from source (clean, harder) or request a prebuilt
   exception (faster, review risk)? *Recommendation: source first.*
3. **Android APK:** no APK in the Flatpak (open releases / user-selected file),
   or bundle a signed APK? *Recommendation: no APK; Flathub-safe.*
4. **Autostart:** Background portal (XDG/freedesktop) or no autostart in the
   Flatpak? *Recommendation: portal, with a clear fallback message.*

## Acceptance criteria

- The Flatpak builds offline from pinned sources and passes
  `flatpak-builder-lint` and AppStream validation.
- A clean-profile install streams phone audio over Wi-Fi, creates `phone-mic`,
  and keeps the latency governor's queue bounded (peak < 16 KB, no persistent
  delay).
- USB works in the USB profile, or the wireless-only limitation is explicit in
  the UI and docs.
- No writes outside the sandbox XDG dirs; no systemd, host PipeWire config, or
  GNOME extension installation.
- The host `install.sh` install remains unchanged and functional alongside the
  spec; the two installs use different ADB ports.
- Documentation covers XDG paths, permissions, APK installation, the GNOME
  extension requirement, and Flathub submission.
