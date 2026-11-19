# Android MicSource Branding, Wireless Debugging, and Phone GUI Plan

**Status:** Tasks 1–4 implemented; Task 5 remains.

**Next agent:** Finish Task 5. Update `docs/USER.md`, `docs/AGENT.md`, and
`README.md` for MicSource branding, phone controls, USB/Wi-Fi pairing, and
device selection. Then validate the APK and USB/Wi-Fi reconnect flow on a
phone, and test ADB server coexistence only in a controlled no-device setup.
Record any unavailable checks as unfinished; do not debug the dormant tray
menu issue.

> **Progress (2026-11-19):** Task 1 now routes all MicSource ADB clients through
> port 5038 by default, stops publishing the bundle as bare `adb`, migrates
> only MicSource-owned links, and preserves foreign links. Four ADB-routing
> unit tests and the 24-case installer suite pass. A live two-server
> coexistence smoke test remains in Task 5, where it can run in a controlled
> environment without competing with the user's active phone connection.
>
> **Progress (2026-11-19):** Task 2 now brands the launcher, notification
> channel, log tag, adaptive icon, and legacy density icons as MicSource while
> preserving `fr.dzx.audiosource`. `assembleDebug` succeeds; APK inspection
> confirms the package, MicSource label, launcher resources, declared
> permissions, and component export settings. Installing over an existing
> phone build with the expected signing key remains a Task 5 device check.
>
> **Progress (2026-11-19):** Task 3 now keeps a native phone control screen
> open, requests microphone/notification permission from the relevant actions,
> refuses to start recording without microphone permission, and binds to the
> service for waiting/streaming/error/stopped state. It includes Start/Stop,
> Android-version-aware Wireless debugging instructions, and a Developer
> options shortcut. The API 14-compatible AppCompat theme is retained. APK
> build passes. Device lifecycle and permission-flow checks remain in Task 5;
> no test phone/emulator was available in this sandbox.
>
> **Progress (2026-11-19):** Task 4 adds host CLI and GUI flows to list and
> select devices, pair using the temporary six-digit code over stdin, connect
> using the separate endpoint, disconnect, and optionally discover
> `_adb-tls-connect._tcp` services with mDNS. The selected serial is saved in
> `[device]` and used across CLI/GUI ADB calls; wireless connect restores the
> existing audio forward. Four stub-backed wireless CLI tests pass, as do
> the ADB routing tests and 24 installer sandbox cases. Physical USB/Wi-Fi
> streaming checks remain in Task 5.

## Goal

Make the phone app visibly and consistently branded as MicSource, give it a
useful native control screen, and let the Linux host pair/connect over Android
Wireless debugging while retaining USB debugging as a supported connection.
Keep ADB private to MicSource so installing its fallback tools cannot replace
system files or unexpectedly disturb other ADB users.

## Audit: bundled ADB scope and interference

The installer currently:

- Prefers the first `adb` found on the installer's `PATH`. It records that
  absolute path in `~/.local/share/micsource/adb.path`.
- If no `adb` is found, stores Google's platform-tools under
  `~/.local/share/micsource/adb-bundle/platform-tools/`.
- Creates `~/.local/bin/adb` pointing at the bundle. It does not use `sudo`,
  write under `/usr/bin` or `/usr/local/bin`, or add all of platform-tools to
  `PATH`. Uninstall removes that link only when it still points to MicSource's
  bundled binary; it leaves a foreign link/file alone.
- Calls ADB through the absolute path in `adb.path` from MicSource scripts.

So the bundle does not replace a system-wide executable or other system-wide
tool. There is one user-scope collision: the new `~/.local/bin/adb` link can
shadow a system `adb` installed later when `~/.local/bin` precedes `/usr/bin`
on `PATH`. ADB clients also share the local server endpoint (default port
5037); AOSP's client code kills and restarts a server whose protocol version
does not match the invoking client. Thus a bundled MicSource client and a
different system/Android Studio client can disrupt each other's active ADB
server, even though their executable files are separate.

**Observed on this host (2026-11-19):** `adb.path` points to
`/home/linuxbrew/.linuxbrew/bin/adb`; `~/.local/bin/adb` is a link to the
MicSource bundle, but the current `PATH` resolves the Linuxbrew executable
first. Both binaries report version `37.0.1-15733141`. No active PATH
shadowing or version mismatch was found in this shell. The risk is conditional
on a different PATH order or a later version change.

**Plan decision:** keep fallback platform-tools inside MicSource's data
directory, stop publishing the bundled binary as bare `adb`, and run all
MicSource ADB operations through one explicit, configurable MicSource server
port (default 5038). Use the same port for install, status, monitor, wireless
pair/connect, and any existing tray ADB polling; do not alter tray menu code
or investigate its dormant menu issue. Preserve a user's unrelated
`~/.local/bin/adb` entry. If the selected port is busy, fail with a clear
message and allow a documented override rather than falling back to port
5037 silently.

## Compatibility decisions

- Change the visible product name and assets to **MicSource**.
- Keep Gradle `applicationId` and namespace `fr.dzx.audiosource` in this work
  so an installed app remains an in-place update. Renaming the package ID is
  a separate migration: Android treats it as a different app, and the host
  currently uses this ID to launch, stop, and install the app.
- Keep USB debugging working. Wireless debugging is an additional transport,
  not a replacement.
- Pairing/connection is initiated by the Linux host because Android Wireless
  debugging pairs a workstation's ADB host with the phone. The phone GUI
  explains how to enable it and reports recording/socket state; it cannot
  silently enable Developer Options or Wireless debugging.
- Android 11 (API 30)+ supports the modern Wireless debugging pairing flow.
  Older Android versions retain USB support. The host presents separate
  pairing and connection endpoints because the pairing port and ADB connect
  port are distinct values shown by Android.

## Implementation tasks

### Task 1: Isolate MicSource's ADB use

**Files:** `linux-install/install.sh`, `linux-install/uninstall.sh`,
`linux-install/assets/micsource`, `micsource-app.py`, `micsource-monitor.py`,
`micsource-tray.py`, config template, installer tests, and user/agent docs.

- Add a single ADB server-port setting and route every MicSource ADB command
  through the same selected client and port, including APK installation,
  device detection, status, service monitoring, and wireless operations.
- Default MicSource to its own local server port (5038); permit a validated
  config override. Never bind the ADB server to non-loopback interfaces.
- Stop creating `~/.local/bin/adb` for newly installed bundles. On upgrade,
  remove that link only if it resolves exactly to MicSource's bundled ADB;
  preserve unrelated files and links.
- Keep system ADB discovery behavior documented. A found system client can
  still be selected for MicSource, but MicSource commands use its isolated
  server port. Do not change global `PATH`, packages, or system services.
- Add stub-backed tests asserting every ADB invocation receives the selected
  port and that install/uninstall neither overwrite nor remove a foreign
  `~/.local/bin/adb`.
- Stub-test that MicSource `get-state` and `forward` operations use only the
  configured endpoint. Verify real server coexistence in Task 5 from a
  controlled no-device environment; do not start a second ADB daemon beside
  the user's active phone connection during this task.

### Task 2: Rebrand the Android app without changing its package identity

**Files:** `app/build.gradle`, `app/src/main/AndroidManifest.xml`, Android
resources, launcher/adaptive icons, `App.java`, notification/service strings,
and references/docs that present the phone app as Audio Source.

- Replace the launcher label, notification channel/title, visible strings,
  logs, and app artwork with MicSource branding.
- Audit the adaptive and legacy launcher icon variants and notification icon;
  provide one coherent MicSource microphone mark with accessible descriptions
  where the UI uses icons.
- Leave internal Java package names and `applicationId` unchanged.
- Build the APK and verify package identity, permissions, exported components,
  launcher label/icon resources, and update installation over the existing
  `fr.dzx.audiosource` app with the expected signing key.

### Task 3: Replace the permission-only activity with a real phone GUI

**Files:** `MainActivity.java`, `RecordService.java`, `RecordThread.java`,
layouts/themes/resources, and Android tests.

- Replace the translucent no-title activity that starts the service and
  immediately finishes with a normal MicSource screen.
- Request microphone and notification permissions in context. Show a clear
  denied-permission state and retry path; never start recording without the
  microphone permission.
- Provide accessible **Start** and **Stop** controls. Preserve the foreground
  microphone service and its notification stop action.
- Show explicit states: permission needed, stopped, waiting for host,
  streaming to host, and recoverable startup/recording error. Drive these
  states from the service/record thread using a local binder or equivalent
  lifecycle-safe callback; do not infer streaming solely from service-running.
- Show a Wireless debugging setup panel with Android-version-aware guidance
  and a button to open Developer Options when available. Explain that actual
  pairing happens on the Linux computer and that the pairing code is
  temporary. Do not store/display the pairing code in the phone app.
- Keep the screen functional across Activity recreation, permission flows,
  and service restarts; avoid creating duplicate recorder threads.
- Add unit/instrumentation coverage for permission states, state transitions,
  Start/Stop idempotency, and Activity/service rebinding.

### Task 4: Add wireless pairing and connection to the Linux host

**Files:** host CLI, `micsource-app.py`, shared ADB helpers, monitor config,
installer templates, tests, and user docs.

- Add an explicit host workflow to pair with the phone's temporary
  `IP:pairing-port` and six-digit pairing code, then connect to the separate
  `IP:connect-port`. Pairing and connecting must be separate actions because
  Android supplies separate endpoints.
- Keep the pairing code out of logs, config files, shell history, and process
  arguments. Use an interactive masked field and pass the code through the
  ADB process's stdin where supported; clear it from the UI after the attempt.
- Support manual endpoint entry first. If ADB mDNS service discovery is
  available, show discovered `_adb-tls-connect._tcp` devices as a convenience;
  retain manual entry when multicast is blocked by the network.
- Display `adb devices -l` results and require/select a serial when multiple
  USB or wireless devices are connected. Persist the selected serial, not a
  short-lived pairing code or dynamic port.
- Add connect, reconnect, and disconnect actions. Preserve the existing
  `localabstract:micsource -> localabstract:audiosource` forward and test it
  over both USB and wireless transports.
- Handle wrong code, expired pairing endpoint, different connect endpoint,
  phone/host on different networks, blocked mDNS, Wi-Fi loss, changed IP/port,
  multiple devices, and permission/ADB authorization errors with actionable
  messages. Never run `adb tcpip 5555` as a substitute for Android 11+
  Wireless debugging.
- Keep USB auto-detection and current CLI workflows passing unchanged.

### Task 5: End-to-end validation and documentation

- Add host tests with an ADB stub for pair/connect/device-list/serial/forward
  actions and for the dedicated server port. Add Android tests for GUI and
  service state.
- Validate on a USB device and an Android 11+ phone using Wireless debugging:
  first-time pairing, reconnect after Wi-Fi loss, and explicit unpair/revoke.
- Confirm MicSource operations leave the default/system ADB server running
  while MicSource's server uses its separate port.
- Update install prompts and `linux-install/docs/USER.md` with USB and Wi-Fi
  setup, Android version requirements, same-network requirement, pairing
  steps, troubleshooting, and how to forget the workstation on the phone.
- Update `linux-install/docs/AGENT.md` with ADB port ownership, selected
  serial flow, package-ID compatibility, and service/UI state architecture.
- Run the Android build/tests, host sandbox tests, Python/shell static checks,
  and verify APK install/update against the existing package identity.

## Acceptance criteria

- The phone launcher and recording notification say MicSource and show the
  MicSource artwork; an existing install updates in place with its app data
  preserved.
- Opening the phone app shows a usable GUI with permission, service, and
  streaming state; Start/Stop are reliable and accessible.
- USB still connects and streams. Android 11+ can pair by Wireless debugging,
  connect using its separate endpoint, and stream over the existing ADB
  forward.
- MicSource's bundled tools stay in its user data directory; no global path,
  package, or executable changes occur. The bare `adb` command does not become
  a MicSource link, and MicSource uses its isolated ADB server port.
- No pairing code is persisted or logged. Multi-device selection is explicit.
- The dormant tray menu issue remains out of scope; no menu debugging is part
  of this plan.

## References

- [Android Debug Bridge: wireless debugging, pairing, and connect](https://developer.android.com/tools/adb)
- [ADB command reference: `pair`, `connect`, and server port `-P`](https://android.googlesource.com/platform/packages/modules/adb/+/refs/heads/main/docs/user/adb.1.md)
- [AOSP ADB client: server-version mismatch handling](https://android.googlesource.com/platform/packages/modules/adb/+/refs/heads/android15-qpr2-s8-release/client/adb_client.cpp)
