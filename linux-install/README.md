# MicSource — Linux Host Installer

MicSource is a fork of the AudioSource Android app; it forwards microphone
audio from an Android device to a Linux host over an adb-forwarded Unix
socket. This directory contains the host-side installation suite.

## Naming

All host-side components are named **micsource** (dirs, scripts, launcher,
systemd unit, icons, GNOME extension). Two Android-identifiers stay unchanged
because they are baked into the APK:

- `fr.dzx.audiosource` — Android package (set in `app/build.gradle`)
- `audiosource` — device-side abstract socket name (created by `RecordThread.java`)

The installer forwards the device socket to the host, mapping
`localabstract:micsource` (host) → `localabstract:audiosource` (device).

## What it installs

| Component | Location | Purpose |
|---|---|---|
| **adb bundle** (optional) | `~/.local/share/micsource/adb-bundle/` | Official Google platform-tools, installed only if `adb` is missing on the host |
| **Build environment** (optional) | `~/.local/share/micsource/build-env/` | Portable Temurin JDK 17 + Android SDK (platform 34, build-tools 34) so the APK can be built without Android Studio; also writes `local.properties` and `build-env.path` |
| **APK** | `~/.local/share/micsource/micsource-release.apk` | Staged copy of the built Android APK |
| **Launcher icon** | `~/.local/share/applications/micsource.desktop` | App-drawer entry (opens the control window) |
| **Control window** | `~/.local/share/micsource/micsource-app.py` | Desktop GUI (GTK 4 + libadwaita): status, service control, install APK, build APK, header menu (Preferences / About), notifications |
| **Stream routing lock** | `~/.config/pipewire/pipewire-pulse.conf.d/10-micsource-stream-lock.conf` | Keeps the virtual-mic player stream locked to the virtual sink (PipeWire/WirePlumber cannot re-route it) |
| **GUI wrapper** | `~/.local/share/micsource/micsource-gui` | Launcher target; shows a helpful notification if the GTK 4 / libadwaita stack is missing |
| **Tray icon script** | `~/.local/share/micsource/micsource-tray.py` | Opt-in legacy tray (GTK 3 + AppIndicator/Ayatana) for KDE/XFCE/etc.; enable from the app's Preferences or `./install.sh --with-tray`. On GNOME use the top-bar tile |
| **systemd service** | `~/.config/systemd/user/micsource.service` | Background monitoring, socket forwarding, audio playback |
| **CLI** | `~/.local/bin/micsource` → `~/.local/share/micsource/micsource` | Command-line client (start/stop/status/run/tray/window/build-apk/install-apk/config) |
| **Config** | `~/.config/micsource/config.ini` | Editable host configuration |
| **GNOME quick settings pill** (optional) | `~/.local/share/gnome-shell/extensions/micsource-tile@micsource.local/` | Quick-settings pill (expandable menu) mirroring the app's Device/Monitoring status; click toggles the service |

## Requirements

- Linux desktop (GNOME tested; works on most XDG desktops)
- Python 3 with PyGObject (`gi.repository.Gtk`) for the control window and tray. The tray icon additionally needs Gtk 3 + `AppIndicator3`/`AyatanaAppIndicator3` (`gir1.2-gtk-3.0`, `gir1.2-ayatanaappindicator3-0.1`); without them it logs the reason to `tray.log` and exits instead of opening a second window — use the control window or the GNOME tile there.
- `paplay` (preferred) or `aplay` for audio playback
- `pactl` (PulseAudio/PipeWire, installed by default on desktop Linux) for the virtual microphone
- `adb` — detected automatically; if absent you will be prompted to install the official adb bundle (downloaded to `~/.local/share/micsource/adb-bundle/` and linked as `~/.local/bin/adb`)
- An Android device with USB debugging authorized

Java + Gradle (JDK 17) and an Android SDK are only needed if you want the
installer to **build** the APK from source. The installer offers to set both
up as a portable environment in `~/.local/share/micsource/build-env/` — no
root, no Android Studio. Signing is optional: without `keystore.properties`
the APK is signed with the automatic debug key, which is fine for local use.
If you skip the build environment, place a prebuilt APK at
`~/.local/share/micsource/micsource-release.apk` instead.

## Installation

```bash
cd linux-install
chmod +x install.sh uninstall.sh
./install.sh
```

The installer will:

1. Check for `adb` on your host; if missing, offer to download and install the official Google platform-tools bundle.
2. Check for a JDK 17 + Android SDK build environment; if missing, offer to install a portable one (needed only to build the APK from source).
3. Locate, build, or stage the MicSource APK.
4. Install the APK to your connected Android device via adb and forward the `audiosource` device socket as `micsource`.
5. Write `~/.config/micsource/config.ini`.
6. Install the app-drawer launcher icon.
7. Install the desktop control window (`micsource-app.py`) and its launcher wrapper (`micsource-gui`).
8. Install the persistent system tray icon script.
9. Install the systemd user service.
10. Optionally install the GNOME panel toggle extension.

After installation, connect your Android device, authorize USB debugging, and
start the service or launch **MicSource** from the app drawer:

```bash
systemctl --user enable --now micsource
```

## Command-line interface

After installation you get a `micsource` command (symlinked into
`~/.local/bin/`):

```bash
micsource start          # start the monitor service (systemd user service)
micsource stop           # stop it
micsource status         # service / adb device / socket-forward status
micsource run            # foreground: forward + stream audio until Ctrl+C
micsource tray           # launch the tray icon
micsource window         # open the desktop control window
micsource build-apk      # build the APK from source and stage it
micsource install-apk    # (re)install the staged APK + set up the forward
micsource config         # open the config folder
micsource help
```

If bash says `micsource: command not found`, add `~/.local/bin` to your PATH
(`export PATH="$HOME/.local/bin:$PATH"`). The installer warns when it detects
that this directory is missing from PATH.

## Usage

**App drawer:** launch "MicSource" to open the **control window** — a desktop
GUI that shows the live status (phone model and connection state, monitoring
with a live level meter) and provides the same actions as the CLI: Start/Stop
Service, Install APK on Device, Open Config Folder, and Build APK (Gradle
build → stage → device install, in one click). It also sends desktop
notifications when the device connects/disconnects and when APK installation
finishes. If PyGObject (`python3-gi`) is missing, the launcher wrapper
notifies you instead of failing silently.

The **background service is the only thing that monitors audio**; the
window/tray cannot stream on their own (one stream, one owner — no
conflicts).

**Tray icon** (optional; `micsource tray`): shows connected/disconnected
state, offers Start / Stop Service, Open Control Window, Open Config
Folder, and Quit. It needs Gtk 3 + AppIndicator3/Ayatana; without those
bindings it writes the error to `~/.local/share/micsource/tray.log` and exits
rather than opening a second window. On GNOME without the appindicator
extension, use the GNOME tile instead (see below).

**Background monitor:** the systemd service sends desktop notifications when
the device connects or disconnects.

**systemd service:**
```bash
systemctl --user start micsource       # start monitoring
systemctl --user stop micsource        # stop
systemctl --user status micsource      # check status
journalctl --user -u micsource -f      # view logs
```

**Config:** edit `~/.config/micsource/config.ini` to set `adb_path`, `serial`
(target device serial), or the host socket name (`host_socket_name`). The
`[audio]` section controls what happens to the phone audio:

```ini
[audio]
play_to_speakers = false  ; play phone audio through your speakers (default OFF)
virtual_mic = true        ; expose the phone mic as a system input device
```

### The "phone-mic" input device (virtual microphone)

While monitoring, MicSource feeds the phone stream into a **virtual input
source** named `phone-mic` ("MicSource-phone-mic" in application pickers).
Any app — browser, VOIP client, recorder — can select it as a microphone.
Technically it is a PipeWire/PulseAudio null-sink (`phone-out`) whose monitor
is remapped into the `phone-mic` input source, which works on both PipeWire
and PulseAudio systems. Verify it appears with:

```bash
pactl list sources short | grep phone-mic
```

The source exists only while monitoring is active; stopping monitoring
(or the service) unloads it automatically. Set `virtual_mic = false` in the
config to disable this. `play_to_speakers = true` also plays the phone audio
out loud through the PC speakers (off by default, so monitoring is silent
unless you opt in).

**How do you know audio is actually flowing?**

- The control window's Monitoring row shows `on — phone audio is streaming`
  with a live input-level bar fed by the monitor's `level` metric.
- `micsource status` returns `audio_seconds=N` — the number of seconds of
  phone audio received since the service started; it should keep growing.
- Play into `phone-mic` from any app (e.g. pavucontrol → Recording tab
  shows the level); the phone audio is not played aloud unless
  `play_to_speakers = true`.
- If forwarding stalls because the phone app wedges (rare; e.g. right after
  an APK re-install), the monitor relaunches the app on the phone
  automatically to recover.

**GNOME quick settings pill:** enable with
`gnome-extensions enable micsource-tile@micsource.local` (or flip it on in the
Extensions app or the app's Preferences). It appears as a pill in the
quick settings grid; its subtitle shows the live state — **Service — off**,
your phone's **model name** once audio is streaming, **Disconnected**, or
**starting…** — the pill is highlighted while the service runs; click
toggles the service, the chevron expands a menu with Device (model name) /
Monitoring status and actions (same info as the control window). Requires
GNOME Shell 47+ (ES-module API); if it does not appear right away, log out
and back in. Note GNOME has **no** classic
tray area without the appindicator extension — use the pill there instead.

## Uninstallation

```bash
./uninstall.sh
```

The uninstaller stops the service, then removes the launcher icon, control
window / tray / monitor scripts, config, systemd unit, GNOME extension and
staged APK, the adb bundle (after asking). It is guarded: directories are only
deleted when they contain MicSource's own files, so an accidentally matching
directory is never wiped. It never touches your Android device, system-wide
packages, or an adb installed by your package manager.

## Files

- `install.sh` — installer orchestration (copies the payloads into your home)
- `uninstall.sh` — simple, safe uninstaller
- `common.sh` — shared helpers and paths used by both scripts
- `assets/` — the payload programs (CLI, tray, monitor, control window, build
  helper, GNOME extension); the repo copy is the source of truth
- `tests/test_install_sandbox.sh` — sandboxed install/uninstall tests
- `config.ini` — host configuration (created on install)
- `docs/USER.md` — end-user guide
- `docs/AGENT.md` — technical reference for agents/maintainers

The control window, GUI wrapper, tray, monitor and `micsource` CLI are
**copied from `linux-install/assets/`** into `~/.local/share/micsource/` at
install time, with the CLI symlinked to `~/.local/bin/micsource` (see "What it
installs"). The deployed copies are outputs — edit the assets, then re-run the
installer; do not hand-edit the installed scripts.
