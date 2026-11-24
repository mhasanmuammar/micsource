# MicSource — End User Guide

MicSource lets you use your Android phone's microphone as an input device on
your Linux computer. The phone records audio and sends it to your PC over a USB
or Wi-Fi adb connection; the PC exposes it as a real microphone ("phone-mic")
that every app can use, and — if you opt in — can also play it through the
speakers.

## First-time setup

1. On your Android phone, enable **Developer options** and turn on **USB
   debugging**. (To use Wi-Fi instead of a cable, see
   [Connecting over Wi-Fi](#connecting-over-wi-fi-wireless-debugging) below —
   it needs Android 11 or newer.)
2. Connect the phone to your Linux PC with a USB cable.
3. On the phone, accept the "Allow USB debugging?" dialog when it appears.
4. Open a terminal on your PC and run the installer:

   ```bash
   cd linux-install
   chmod +x install.sh
   ./install.sh
   ```

5. When asked about `adb`, say **Yes** if you don't already have it installed.
   The installer stores Google's platform-tools privately under
   `~/.local/share/micsource/adb-bundle/`. MicSource uses its own local ADB
   server port (5038); it does not replace your system `adb` or add a bundled
   `adb` command to your `PATH`.
   Ancient tray: not needed on GNOME — the GNOME top-bar tile is the
   primary top-bar control. If you want the legacy appindicator tray
   (KDE/XFCE/other desktops), run `./install.sh --with-tray` or enable it
   from the app: **MicSource → Preferences → Startup & Panel → Tray Icon**
   (the installer tells you the binding package when it is missing).
6. When the installer finishes, launch **MicSource** from your app drawer —
   the MicSource control window opens, showing the status and control buttons.

## Connecting over Wi-Fi (Wireless debugging)

Instead of a cable, Android 11+ phones can connect over your local network.
Requirements: **Android 11 or newer**, phone and PC on the **same Wi-Fi
network**, and Wi-Fi enabled on the phone. Pairing is always started from
the computer; the phone only shows the temporary addresses and code.

1. On the phone: **Settings → Developer options → Wireless debugging** (turn
   it on).
2. Tap **Pair device with pairing code**. The phone shows a six-digit code
   plus a `Pairing IP:port` (e.g. `192.168.1.20:41000`) — both are temporary
   and change each time.
3. On the PC, pair (the code is typed at a hidden prompt; it is never saved
   to files, logs, or shell history):

   ```bash
   micsource wireless-pair 192.168.1.20:41000
   ```

4. The Wireless debugging screen now shows a **Connect IP:port** address
   (different from the pairing port). Connect to it:

   ```bash
   micsource wireless-connect 192.168.1.20:38000
   ```

5. That is it — the mic socket forward is re-established automatically and
   the selected device is remembered. `micsource status` should show the
   device online.

You can do the same from the control window: the **Connected devices** group
has **Pair**, **Connect**, **Refresh devices**, **Discover**, and
**Disconnect** fields/buttons for the same addresses.

- **Reconnect after Wi-Fi loss / IP change:** run `micsource
  wireless-connect IP:PORT` again with the phone's current address (the
  phone shows it in Developer options → Wireless debugging). If pairing was
  never lost, no re-pairing is needed.
- **Multiple phones:** run `micsource devices` to list serials, then
  `micsource device-select SERIAL` to pick which one MicSource uses (stored
  in the config; `micsource device-select none` clears it).
- **mDNS convenience:** `micsource wireless-discover` lists already-paired
  Wi-Fi devices ADB finds on the network (needs multicast; if it finds
  nothing, manual address entry always works).
- **Forget this computer on the phone:** in **Developer options → Wireless
  debugging**, open the paired-computer entry and remove it (wording varies
  by Android version), or revoke all host authorizations with **Revoke USB
  debugging authorizations**. The next connection then asks for a fresh
  pairing.

## Daily use

- Launch **MicSource** from the app drawer (or run `micsource window`) to open
  the control window. It shows whether your phone is connected (its
  **Device** row shows the phone's model name once known), and whether audio
  is being forwarded (the **Monitoring** row has a live input-level bar).
- Use the window buttons: **Start Service** / **Stop Service** (this starts and
  stops the actual microphone forwarding — the background service is the only
  thing that streams audio), **Install APK on Device**, **Build APK (from
  source)** (builds and installs in one click), and **Open Config Folder**.
  The window itself cannot stream; it only shows status and controls the
  service.
- Your desktop shows a notification when the phone connects or disconnects
  (from the background monitor service).
- On GNOME, the **quick settings pill** is the control surface (next to the
  Wi-Fi / Bluetooth pills in the system pull-down). Its subtitle shows the
  live state: **Service — off**, your phone's **model name** once audio is
  streaming, **Disconnected**, or **starting…** (it refreshes every few
  seconds and the pill is highlighted while the service runs); click the
  pill to start or stop the background service; click its **chevron** to
  expand a menu with the same **Device** (model name) and **Monitoring**
  status as the control window, plus Start/Stop Service and Open Control
  Window actions. It can be toggled from the app (**Preferences → Startup &
  Panel → GNOME Top-bar Tile**); if the pill does not appear after enabling,
  log out and back in (or flip the Preferences switch off/on) so the shell
  reloads the extension.
- A legacy tray icon exists for other desktops and is **opt-in**: enable it
  in the app (**Preferences → Startup & Panel → Tray Icon**) or start it
  once with `micsource tray`. It uses the StatusNotifierItem protocol and
  offers Start / Stop Service, Open Control Window and Open Config Folder.
  The desktop session must provide a StatusNotifier watcher; GNOME requires
  the AppIndicator shell extension. If no watcher is running, MicSource logs
  the reason to `~/.local/share/micsource/tray.log` and exits.
- By default the phone audio is **not** played through your speakers — it
  silently appears as the "phone-mic" input device. Turn on `play_to_speakers`
  in the config if you also want to hear it.
- While the service runs, your phone's microphone appears on the PC as a real
  input device named **MicSource (phone mic)** (`phone-mic`), selectable in
  browsers, VOIP apps and recorders — not just played through the speakers.
- If the connection drops, you get a "disconnected" notification; reconnect
  the cable / re-authorize adb and press **Start Service** (or it recovers
  by itself while the service is running).

## Command-line interface

A `micsource` command is installed at `~/.local/bin/micsource`:

```bash
micsource start          # start the background monitor service
micsource stop           # stop it
micsource status         # service / adb device / socket-forward status
micsource run            # foreground: forward + play audio until Ctrl+C
micsource tray           # launch the tray icon
micsource window         # open the desktop control window
micsource build-apk      # build the APK from source and stage it
micsource install-apk    # (re)install the APK on the phone and set up the forward
micsource devices        # list USB and Wi-Fi devices (adb devices -l)
micsource device-select SERIAL   # select which phone MicSource uses ('none' clears)
micsource wireless-pair IP:PORT  # pair via Wireless debugging (asks for the code)
micsource wireless-connect IP:PORT    # connect to the separate Wi-Fi endpoint
micsource wireless-disconnect [IP:PORT] # drop a Wi-Fi connection
micsource wireless-discover      # show paired Wi-Fi devices found by ADB mDNS
micsource config         # open the config folder
micsource help
```

If bash says `micsource: command not found`, add `~/.local/bin` to your PATH
(`export PATH="$HOME/.local/bin:$PATH"`), then re-run `./install.sh` or open a
new terminal.

## Configuration

Edit `~/.config/micsource/config.ini` (or open "Open Config Folder" from the
tray menu). Common settings:

- `serial` — the serial number of your Android device (useful if you have more
  than one). Leave blank to use the first device. Prefer setting it with
  `micsource device-select SERIAL` (or **Refresh devices** in the control
  window) — both USB and Wi-Fi serials work, and the choice is remembered.
- `backend` — `auto` (uses `paplay`, falls back to `aplay`).
- `adb_path` — only needed if your adb lives somewhere unusual.
- `server_port` — MicSource's local ADB server port (default `5038`; system
  ADB uses `5037`). Leave the default unless you need to resolve a local port
  conflict; `5037` is reserved for the system ADB server.
- `[audio] play_to_speakers` — `false` (default) keeps the phone audio silent
  on the PC (mic-only mode). Set `true` to also play it out loud.
- Easier: edit these from the app — **MicSource → Preferences → Audio**
  (instant-apply switches; they take effect the next time the service
  starts) and **Startup & Panel** for the autostart / top-bar tile / tray
  toggles.
- `[audio] virtual_mic` — `true` (default) exposes the phone microphone as a
  PC input device ("phone-mic") usable by every app. Set `false` to skip it.

Do not change `device_socket_name=audiosource` or the Android package — both
are baked into the phone app and must stay as-is.

## How do I know the PC is really using my phone's mic?

1. **Control window:** it shows `Monitoring: on (background service) — N s
   forwarded` (a live counter) while the service is streaming. `micsource
   status` also prints `audio_seconds=N`, which grows as long as audio flows,
   plus `dropped_seconds=M` — the audio MicSource discarded to keep latency
   bounded (see *Audio is delayed over Wi-Fi* below).
2. **Input device:** run `pactl list sources short | grep phone-mic` (or open
   pavucontrol → Input Devices): "MicSource (phone mic)" appears while
   monitoring runs, and disappears when you stop it.
3. **In apps:** in a meeting/chat app's audio settings, pick
   **MicSource (phone mic)** as the microphone and speak — its level meter
   should react. In pavucontrol's Recording tab, apps show which device they
   record from.
4. **Speakers:** nothing is played aloud by default; set
   `play_to_speakers = true` if you also want to hear the phone audio in real
   time.

## Uninstalling

```bash
./uninstall.sh
```

This removes everything the installer put on your computer. It asks before
deleting the downloaded adb bundle and never touches unrelated directories.
It does not remove anything from your Android phone (the app stays installed
there unless you uninstall it separately).

## Troubleshooting

| Problem | Fix |
|---|---|
| Tray icon is visible, but clicking it opens no menu | Known unfinished issue in the StatusNotifier tray. It is documented for a later development cycle; use the MicSource control window or GNOME top-bar tile for controls in the meantime. |
| Tray icon never shows "connected" | Make sure USB debugging is authorized on the phone and the screen is unlocked. The tray is opt-in: enable it from the app (**Preferences → Startup & Panel → Tray Icon**). The desktop session must provide a StatusNotifier watcher; GNOME additionally needs the **KStatusNotifier / AppIndicator shell extension** (`appindicatorsupport@rgcjonas.gmail.com`) because GNOME has no built-in StatusNotifier area. Watcher errors are reported in the toggle's toast / Activity log and `~/.local/share/micsource/tray.log`. On GNOME, the top-bar tile works without the extension. |
| Launching "MicSource" shows a notification about PyGObject | The window needs GTK 4 + libadwaita: `sudo apt install python3-gi gir1.2-gtk-4.0 gir1.2-adw-1` (Debian/Ubuntu) or `sudo dnf install python3-gobject` (Fedora), then launch MicSource again. |
| No sound from the PC speakers | That is the default — the phone audio only appears as the `phone-mic` input device. Set `play_to_speakers = true` in the config (then check `paplay`/`aplay` is installed and your volume). |
| "phone-mic" missing from `pactl` / app pickers | Monitoring must be running — the device is created when audio forwarding starts and removed when it stops. If monitoring is on but the device is missing, check `pactl` exists; config flags: set `[audio] virtual_mic = true`.
| No voice activity in GNOME Settings / the volume slider does nothing | The service must be running (`micsource status`); the meter only moves while the background service streams. Routing self-heals within ~5 s after the service (re)starts; `micsource stop && micsource start` then pick **MicSource (phone mic)** in the panel. |
| Phone sound suddenly comes out of the PC speakers (without `play_to_speakers`) | The audio policy re-routed the stream; the service repairs this itself within ~5 s. If it recurs, `micsource stop && micsource start`, and re-run install.sh so `~/.config/pipewire/pipewire-pulse.conf.d/10-micsource-stream-lock.conf` is restored. |
| Monitoring stuck at 0 seconds | Confirm RECORD_AUDIO was granted on the phone (and the app can record — check its notification says "recording"). After an APK reinstall, `micsource stop && micsource start` relaunches the phone app; the monitor also self-recovers within ~20 s by opening the app with `--ez start true`. If it still stays at 0, open MicSource on the phone once and tap **Start microphone** (the service is private, so Android blocks direct starts from adb). |
| Audio is delayed over Wi-Fi (delay grows after a pause, never catches up) | Fixed in the current monitor: it keeps at most 16 KB (~186 ms) queued for the player and drops surplus audio, so a Wi-Fi burst can no longer build a permanent backlog. Check `micsource status` — `dropped_seconds` normally stays near 0.2 % of `audio_seconds` (e.g. 0–2 s dropped per 10 min). If `dropped_seconds` climbs much faster, the Wi-Fi link is too weak; move closer to the AP or switch to USB. Re-run `./install.sh` and restart the service after upgrading to get the bounded-queue monitor. |
| Audio went silent but the phone still shows the recording notification | The audio player on the PC died; the monitor respawns it within ~5–10 s and logs `no live audio players; pausing pump` in `journalctl --user -u micsource -f`. If it does not recover, `micsource stop && micsource start`. |
| `adb: command not found` | Re-run `./install.sh` and agree to install the private ADB bundle. MicSource uses the selected binary directly; it does not need `adb` on your shell `PATH`. |
| Wireless pairing fails ("already paired", wrong code, or timeout) | Codes and pairing addresses are temporary — open **Pair device with pairing code** on the phone again and use the fresh `Pairing IP:port` and code immediately; pair and connect ports are different, so use the **Connect IP:port** for `wireless-connect`. |
| Phone and PC on different networks / pairing finds nothing | Both devices must be on the same Wi-Fi network; guest/AP-isolated networks block device-to-device traffic. If mDNS discovery finds nothing (`micsource wireless-discover`), multicast may be blocked — enter the addresses manually. |
| Wi-Fi connection dropped after sleep or network change | Re-run `micsource wireless-connect IP:PORT` with the phone's current address from **Developer options → Wireless debugging**; re-pair only if the phone forgot this computer. |
| Multiple phones connected, wrong one used | `micsource devices` lists serials; `micsource device-select SERIAL` picks the one MicSource uses (the control window's **Refresh devices** does the same). |
| `MicSource ADB server port 5038 is unavailable` | Another process holds MicSource's isolated ADB port. Free the port or set a different one in `server_port` (never `5037` — that is reserved for the system ADB server, which MicSource leaves alone). |
| `micsource: command not found` | Add `~/.local/bin` to your PATH: `export PATH="$HOME/.local/bin:$PATH"`. |
| Service won't start | Run `systemctl --user status micsource` and `journalctl --user -u micsource -f` for logs. |
| Installer can't build the APK | First run of Gradle downloads dependencies and needs network. If it still fails, re-run `./install.sh` and accept the "portable build environment" prompt, check `journalctl`/the activity log in the control window, or place a prebuilt APK at `~/.local/share/micsource/micsource-release.apk`. |
| `INSTALL_FAILED_UPDATE_INCOMPATIBLE` on install | The device already runs a differently-signed copy of the app (e.g. the upstream release build). Our debug-signed APK cannot update it; `install-apk` will offer to uninstall the existing app first (its settings are lost) — or keep using the existing app. |

## Files on your computer

- `~/.local/bin/micsource` — CLI command (symlink)
- `~/.local/share/applications/micsource.desktop` — app drawer icon
- `~/.local/share/micsource/` — CLI / control window / GUI wrapper / tray / monitor scripts, staged APK, adb bundle
- `~/.config/micsource/config.ini` — your settings
- `~/.config/systemd/user/micsource.service` — background service
- `~/.config/autostart/micsource-tray.desktop` — optional tray autostart entry (written only when you enable **Tray Icon** in the app)
- `~/.config/pipewire/pipewire-pulse.conf.d/10-micsource-stream-lock.conf` — keeps the player stream locked to the virtual sink
- `~/.local/share/icons/hicolor/scalable/apps/micsource.svg` — tray icon
