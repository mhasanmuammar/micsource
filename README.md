# MicSource

Use your Android phone's microphone as a real input device on Linux.
MicSource is a fork of the AudioSource Android app plus a Linux host suite:
the phone app records and streams mic audio to the PC over an adb-forwarded
socket, where it appears as a system microphone ("phone-mic") for any app —
optionally with speaker playback.

- **`app/`** — the Android app (package `fr.dzx.audiosource`, shipped as
  **MicSource**): native control screen with Start/Stop, permission states,
  live service/streaming status, and Wireless debugging guidance.
- **`linux-install/`** — the Linux host installer, CLI, control window, tray,
  monitor service, and docs. Start with [`linux-install/README.md`](linux-install/README.md);
  end-user guide in [`linux-install/docs/USER.md`](linux-install/docs/USER.md),
  maintainer reference in [`linux-install/docs/AGENT.md`](linux-install/docs/AGENT.md).

Connect the phone over **USB** or over **Wi-Fi** (Android 11+ Wireless
debugging, paired from the computer), pick between multiple devices with
`micsource device-select`, and keep ADB private: MicSource uses its own
isolated ADB server port (5038) and never touches the system ADB (5037).
