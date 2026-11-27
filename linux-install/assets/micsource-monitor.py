#!/usr/bin/env python3
"""
MicSource systemd user service.

Background monitoring / detection / config for the MicSource host side.
Runs as the user (no root). Responsibilities:
  * Keep the adb socket forward active (re-establish if dropped).
  * Start the device app when it comes online (rate limited).
  * Forward received PCM audio (16-bit mono 44.1 kHz) to paplay/aplay.
  * Expose a control Unix socket for status queries and restarts.
"""
import array
import configparser
import fcntl
import math
import os
import re
import socket
import subprocess
import sys
import threading
import time

from micsource_adb import (
    DEFAULT_SERVER_PORT,
    command as adb_command,
    server_port_error,
    validate_server_port,
)

try:
    import sys as _sys
    _sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    from paths import (DATA_DIR, CONFIG_DIR, CONFIG_PATH, ADB_PATH_FILE,
                      CONTROL_SOCKET, STATE_DIR, RUNTIME_DIR)
except Exception:
    DATA_DIR = os.path.expanduser("~/.local/share/micsource")
    CONFIG_DIR = os.path.expanduser("~/.config/micsource")
    CONFIG_PATH = os.path.join(CONFIG_DIR, "config.ini")
    ADB_PATH_FILE = os.path.join(DATA_DIR, "adb.path")
    CONTROL_SOCKET = os.path.join(DATA_DIR, "micsource.sock")
    STATE_DIR = os.path.expanduser("~/.local/state/micsource")
    RUNTIME_DIR = os.path.expanduser("/run/user/%d/micsource" % os.getuid())

ANDROID_PKG = "fr.dzx.audiosource"  # Android package (baked into the APK)
DEVICE_SOCKET = "audiosource"       # Device-side socket (RecordThread)
DEFAULT_HOST_SOCKET = "micsource"   # Host side of the adb forward

running = True
audio_procs = []
audio_lock = threading.Lock()

# Live input level (metering): RMS of the pumped PCM, smoothed with a fast
# attack / slow release and exposed over the control socket (`level`).
_audio_level = 0.0     # smoothed 0..1 (dBFS mapped: -60..-15 dB -> 0..1)
_level_update = 0.0    # time.time() of the last sample-consuming update
_level_lock = threading.Lock()

ADB_CMD = "adb"
ADB_SERVER_PORT = DEFAULT_SERVER_PORT
SERIAL = None

# Device name lookup cache
STATE = {"device_name": {}, "device_name_serial": {}}
HOST_SOCKET = DEFAULT_HOST_SOCKET


def _log(msg):
    print(f"[micsource-monitor] {msg}", flush=True)


def device_name():
    """Device model lookup via adb -- supports uppercase/lowercase getprop."""
    global SERIAL

    serial = SERIAL or ""
    cached = STATE["device_name"].get(serial)
    if cached:
        return str(cached)
    # reset cache entry when a NEW serial is seen (handles replug)
    if serial != STATE["device_name_serial"].get("active"):
        STATE["device_name"] = {}
        STATE["device_name_serial"]["active"] = serial

    value = ""
    for prop in ("ro.product.marketname", "ro.product.model",
                 "ro.product.vendor.model", "ro.product.brand"):
        _rc, out, _err = run_adb(
            ["shell", "getprop", str(prop)], timeout=6)
        value = str(out).strip()
        if value:
            break
    if value:
        STATE["device_name"][serial] = value
    return value


def _load_config():
    global ADB_CMD, ADB_SERVER_PORT, SERIAL, HOST_SOCKET
    adb_path = ""
    server_port = str(DEFAULT_SERVER_PORT)
    # Environment wins over config.ini (see paths.py): the Flatpak must stay
    # on its private server even if the config was copied from the host.
    env_port = os.environ.get("MICSOURCE_ADB_SERVER_PORT", "").strip()
    if env_port:
        server_port = env_port
    serial = ""
    host_socket = ""
    parser = configparser.ConfigParser()
    try:
        parser.read(CONFIG_PATH)
        adb_path = parser.get("adb", "adb_path", fallback="").strip()
        if not env_port:
            server_port = parser.get("adb", "server_port", fallback=server_port).strip()
        serial = parser.get("device", "serial", fallback="").strip()
        host_socket = parser.get("socket", "host_socket_name", fallback="").strip()
    except Exception:
        pass
    if not adb_path:
        try:
            with open(ADB_PATH_FILE) as fh:
                adb_path = fh.read().strip()
        except OSError:
            adb_path = ""
    ADB_CMD = adb_path or "adb"
    try:
        ADB_SERVER_PORT = validate_server_port(server_port)
    except ValueError as exc:
        ADB_SERVER_PORT = DEFAULT_SERVER_PORT
        _log(f"invalid [adb] server_port ({exc}); using {DEFAULT_SERVER_PORT}")
    SERIAL = serial or None
    HOST_SOCKET = host_socket or DEFAULT_HOST_SOCKET


def _run_adb(args, timeout, serial):
    """Run adb with an optional device serial; never raises."""
    cmd = adb_command(ADB_CMD, ADB_SERVER_PORT, args, serial)
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        if proc.returncode:
            port_error = server_port_error(ADB_SERVER_PORT, proc.stderr)
            if port_error:
                _log(port_error)
        return proc.returncode, proc.stdout, proc.stderr
    except FileNotFoundError:
        return 127, "", f"adb not found: {ADB_CMD}"
    except subprocess.TimeoutExpired:
        return 124, "", "adb timed out"
    except OSError as exc:
        return 1, "", str(exc)


def run_adb(args, timeout=6):
    return _run_adb(args, timeout, SERIAL)


def run_adb_all(args, timeout=6):
    """Run an ADB command without filtering by the selected serial."""
    return _run_adb(args, timeout, None)


def run_adb_for(serial, args, timeout=6):
    return _run_adb(args, timeout, serial)


def device_online():
    rc, out, _err = run_adb(["get-state"], timeout=4)
    if rc != 0 and SERIAL:
        # The selected serial can go stale when a wireless debugging port
        # changes. With a single connected device, unqualified ADB still
        # resolves the right transport.
        rc, out, _err = run_adb_all(["get-state"], timeout=4)
    return rc == 0 and out.strip() == "device"


def socket_forwarded():
    rc, out, _err = run_adb_all(["forward", "--list"], timeout=4)
    return rc == 0 and (f"localabstract:{HOST_SOCKET}" in out)


def ensure_forward():
    """(Re)establish the host/socket forward. Returns (ok, stderr)."""
    # First try without a forced serial (works when only one device)
    run_adb_all(["forward", "--remove", f"localabstract:{HOST_SOCKET}"], timeout=4)
    rc, _out, err = run_adb_all(
        ["forward", f"localabstract:{HOST_SOCKET}", f"localabstract:{DEVICE_SOCKET}"],
        timeout=6,
    )
    if rc == 0:
        return True, ""
    # If multiple devices, the error is "more than one device/emulator";
    # retry with the selected serial. Wireless serials (ip:port) can fail
    # with "device not found" for forward; fall back to USB serial if
    # another device is online.
    lowered = (err or _out or "").lower()
    if "more than one" in lowered or "device not found" in lowered:
        # A wireless device can appear under both its ip:port and mDNS
        # transport serial. Retry another online transport without mutating
        # the selected serial used by status and shell commands.
        rc2, out2, _ = run_adb_all(["devices"], timeout=4)
        if rc2 == 0:
            for line in out2.splitlines():
                parts = line.split()
                if len(parts) >= 2 and parts[1] == "device" and parts[0] != SERIAL:
                    rc, _out, err = run_adb_for(
                        parts[0],
                        ["forward", f"localabstract:{HOST_SOCKET}",
                         f"localabstract:{DEVICE_SOCKET}"],
                        timeout=6,
                    )
                    if rc == 0:
                        return True, ""
                    break
    return rc == 0, err


def start_device_service():
    run_adb(["shell", "am", "force-stop", ANDROID_PKG], timeout=8)
    rc, _out, err = run_adb(
        ["shell", "am", "start", "-n", f"{ANDROID_PKG}/.MainActivity",
         "--ez", "start", "true"], timeout=10
    )
    return rc == 0, err


# --------------------------------------------------------------------------
# Virtual microphone (null-sink + remap-source).
#
# While monitoring, the PCM stream from the phone is played into a null-sink
# ("phone-out") whose monitor source is remapped into a virtual input source
# named "phone-mic" ("MicSource-phone-mic" in application pickers), so apps
# (browsers, VOIP, recorders, ...) can use the phone mic as a normal input
# device. PipeWire's compat layer does not implement module-pipe-source's
# data path, hence this design. Speaker playback is controlled by
# [audio] play_to_speakers (default true).
# --------------------------------------------------------------------------
VMIC_NAME = "phone-mic"
_sink_mod = None
_src_mod = None
_vmic_lock = threading.Lock()
_vm_ok = False
_pumping = False
_pump_epoch = 0
_pcm_bytes = 0
audio_procs = []

# Latency governor. The player pipe is the only unbounded queue between the
# network and the speakers: if a Wi-Fi burst fills it, the input rate equals
# the playback rate, so the backlog never drains and every later sample plays
# late (observed: 52 KiB queued = ~0.6 s permanent delay). Keep at most
# ~186 ms of 44.1 kHz s16 mono queued instead and drop the surplus.
PLAYER_PIPE_BYTES = 16384
_FIONREAD = 0x541B
F_SETPIPE_SZ = getattr(fcntl, "F_SETPIPE_SZ", 1031)
F_GETPIPE_SZ = getattr(fcntl, "F_GETPIPE_SZ", 1032)
_DROPPED_LOG_SECONDS = 10.0
_dropped_total = 0
_dropped_since_log = 0
_dropped_log_at = 0.0


def _cfg_bool(section, key, default):
    parser = configparser.ConfigParser()
    try:
        parser.read(CONFIG_PATH)
        val = parser.get(section, key, fallback="").strip().lower()
        return default if not val else val not in ("0", "no", "false", "off")
    except Exception:
        return default


def _speakers_enabled():
    return _cfg_bool("audio", "play_to_speakers", True)


def _vmic_enabled():
    return _cfg_bool("audio", "virtual_mic", True)


def _vmic_running():
    # Is a source named VMIC_NAME already registered in the audio server?
    try:
        res = subprocess.run(["pactl", "list", "sources", "short"],
                             capture_output=True, text=True, timeout=5)
        for line in (res.stdout or "").splitlines():
            parts = line.split()
            if len(parts) >= 2 and parts[1] == VMIC_NAME:
                return True
    except Exception:
        pass
    return False


def _vmic_cleanup_leftovers():
    """Unload phone-out / phone-mic modules left by other runs, so this
    instance owns (and can later unload) the whole chain."""
    groups = []
    for kind, names in (("sinks", ("phone-out",)), ("sources", (VMIC_NAME,))):
        try:
            res = subprocess.run(["pactl", "list", kind],
                                 capture_output=True, text=True, timeout=5)
        except Exception:
            continue
        owned = None
        for line in (res.stdout or "").splitlines():
            text = line.strip()
            if text.startswith("Name:") and text.split(":", 1)[1].strip() in names:
                owned = True
            elif owned and text.startswith("Owner Module:"):
                idx = text.split(":", 1)[1].strip()
                if idx.isdigit() and idx not in groups:
                    groups.append(idx)
                owned = None
    for idx in groups:
        try:
            subprocess.run(["pactl", "unload-module", idx],
                           capture_output=True, timeout=5)
        except Exception:
            pass
    return len(groups)


def _phone_out_exists():
    try:
        res = subprocess.run(["pactl", "list", "sinks", "short"],
                             capture_output=True, text=True, timeout=5)
        for line in (res.stdout or "").splitlines():
            parts = line.split()
            if len(parts) >= 2 and parts[1] == "phone-out":
                return True
    except Exception:
        pass
    return False


def _vmic_start():
    """Create the phone-mic input source (null-sink + remap-source).

    PipeWire's PulseAudio compat layer does not implement the data path of
    module-pipe-source (it registers a silent source), so the classic FIFO
    approach stays silent on PipeWire systems. Instead the phone stream is
    played into a null-sink whose monitor is remapped into a real input
    source named phone-mic. Never raises."""
    global _sink_mod, _src_mod, _vm_ok
    with _vmic_lock:
        if _vm_ok or not _vmic_enabled():
            return
        if _phone_out_exists():
            stale = _vmic_cleanup_leftovers()
            if stale == 0:
                _sink_mod = _src_mod = None  # created by another live instance
                _vm_ok = True
                return
            _log(f"recreating leftover phone-* audio modules ({stale})")
        try:
            res = subprocess.run(
                ["pactl", "load-module", "module-null-sink",
                 "sink_name=phone-out",
                 "sink_properties=device.description=MicSource-phone-sink"],
                capture_output=True, text=True, timeout=10)
        except FileNotFoundError:
            _log("virtual mic unavailable: pactl not found")
            return
        except Exception as exc:
            _log(f"virtual mic null-sink failed: {exc}")
            return
        if res.returncode != 0:
            _log("virtual mic sink unavailable: "
                 + ((res.stderr or res.stdout or "").strip()[:120]
                    or "module-null-sink failed"))
            return
        _sink_mod = (res.stdout or "").strip() or None
        try:
            res = subprocess.run(
                ["pactl", "load-module", "module-remap-source",
                 "master=phone-out.monitor",
                 f"source_name={VMIC_NAME}",
                 "source_properties=device.description=MicSource-phone-mic",
                 "channels=1", "master_channel_map=mono", "channel_map=mono",
                 "remap=mono"],
                capture_output=True, text=True, timeout=10)
        except Exception as exc:
            _log(f"virtual mic remap-source failed: {exc}")
            return
        if res.returncode != 0:
            _log("virtual mic remap failed; apps can use "
                 "'Monitor of MicSource-phone-sink' as input")
            return
        _src_mod = (res.stdout or "").strip() or None
        _vm_ok = True
        _log(f"virtual microphone source '{VMIC_NAME}' ready")


def _vmic_stop():
    global _sink_mod, _src_mod, _vm_ok
    with _vmic_lock:
        _vm_ok = False
        for idx in (_src_mod, _sink_mod):
            if idx is not None:
                try:
                    subprocess.run(["pactl", "unload-module", str(idx)],
                                   capture_output=True, timeout=5)
                except Exception:
                    pass
        _src_mod = _sink_mod = None


def _set_stdin_nonblocking(child):
    if child is None or child.stdin is None:
        return
    try:
        fd = child.stdin.fileno()
        flags = fcntl.fcntl(fd, fcntl.F_GETFL)
        fcntl.fcntl(fd, fcntl.F_SETFL, flags | os.O_NONBLOCK)
    except Exception:
        pass


def _pipe_occupancy(fd):
    """Bytes currently queued in a pipe (works on the write end too)."""
    buf = array.array("i", [0])
    fcntl.ioctl(fd, _FIONREAD, buf, True)
    return max(0, buf[0])


def _set_player_pipe_size(fd):
    """Shrink the player pipe to the latency budget (best effort).

    Admission control in `_write_player` still bounds the queue when the
    kernel refuses to resize a pipe (e.g. it already holds more data)."""
    try:
        if fcntl.fcntl(fd, F_GETPIPE_SZ) > PLAYER_PIPE_BYTES:
            fcntl.fcntl(fd, F_SETPIPE_SZ, PLAYER_PIPE_BYTES)
    except OSError:
        pass


def _even_chunk(carry, data):
    """Split byte data on a 16-bit sample boundary.

    A drop of an odd number of bytes would swap every following sample's
    halves (loud noise), so the odd trailing byte is carried to the next
    chunk instead of being played or discarded.
    """
    buf = carry + data
    cut = len(buf) - (len(buf) % 2)
    return buf[:cut], buf[cut:]


def _write_player(fd, data):
    """Queue as much PCM as fits in the latency budget.

    Returns the number of bytes accepted; the caller drops the rest. Writing
    the fitting prefix (rather than dropping a whole early chunk) keeps the
    loss proportional to the actual network excess instead of silencing
    audio whenever the pipe is nearly full. Data must contain whole 16-bit
    samples (`_even_chunk`), and the returned count is kept even so a drop
    cannot swap sample halves.
    """
    if not data:
        return 0
    try:
        queued = _pipe_occupancy(fd)
        capacity = fcntl.fcntl(fd, F_GETPIPE_SZ)
    except OSError:
        queued, capacity = 0, PLAYER_PIPE_BYTES
    free = min(capacity, PLAYER_PIPE_BYTES) - queued
    count = min(len(data), free)
    count -= count % 2
    if count <= 0:
        return 0
    try:
        return os.write(fd, data[:count])
    except (BlockingIOError, OSError):
        return 0


def _live_players(procs):
    return [child for child in procs if child.poll() is None]


def _note_dropped(count):
    """Count/rate-limit reporting of audio dropped to protect latency."""
    global _dropped_total, _dropped_since_log, _dropped_log_at
    if count <= 0:
        return
    _dropped_total += count
    _dropped_since_log += count
    now = time.monotonic()
    if now - _dropped_log_at >= _DROPPED_LOG_SECONDS:
        _log(f"latency guard dropped {_dropped_since_log} bytes "
             f"(~{_dropped_since_log / 88200.0:.2f}s) of stale audio")
        _dropped_since_log = 0
        _dropped_log_at = now


# Env props for the players: a distinctive media.role identifies MicSource
# streams, and the node.* properties ask WirePlumber/PipeWire never to
# re-route or fall back. Without them PipeWire (observed on 1.6.8) moves the
# --device=phone-out stream onto the desktop's default speakers via
# stream-restore/WirePlumber policy, leaving phone-mic silent and leaking
# the phone audio to the physical speakers.
_PLAYER_ENV = dict(os.environ)
_PLAYER_ENV["PULSE_PROP"] = ("media.role=MicSource "
                             "node.dont-move=true "
                             "node.dont-fallback=true")


def _spawn_player(args_extra=None):
    """Spawn one paplay consuming raw PCM on stdin; args_extra may target a
    sink (e.g. --device=phone-out for the virtual-mic chain)."""
    argv = ["paplay", "--raw", "--format=s16le", "--rate=44100", "--channels=1",
            "--latency=200"]
    if args_extra:
        argv.extend(args_extra)
    child = None
    try:
        child = subprocess.Popen(
            argv,
            stdin=subprocess.PIPE,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            env=_PLAYER_ENV,
            bufsize=0,
        )
    except (FileNotFoundError, OSError):
        return None
    _set_stdin_nonblocking(child)
    try:
        _set_player_pipe_size(child.stdin.fileno())
    except (AttributeError, OSError):
        pass
    return child


def start_audio():
    """Start forwarding device PCM audio (speakers and/or virtual mic)."""
    global _pumping, _pump_epoch
    with audio_lock:
        if _pumping:
            live = _live_players(audio_procs)
            if live:
                audio_procs[:] = live
                _vmic_start()
                return True
            # Every player exited (sink torn down, paplay crash, ...).
            # Streaming into their dead pipes would keep counting audio
            # while nothing is audible, so reset and spawn fresh players.
            _log("all audio players exited; restarting them")
            _pumping = False
            audio_procs.clear()
            _pump_epoch += 1
        kids = []
        if _vmic_enabled():
            _vmic_start()
            if _vm_ok:
                kid = _spawn_player(args_extra=["--device=phone-out"])
                if kid is None:
                    _log("warning: no paplay found; phone-mic will be silent")
                else:
                    kids.append(kid)
        if _speakers_enabled():
            kid = _spawn_player()
            if kid is None:
                _log("no paplay found; speaker playback skipped")
            else:
                kids.append(kid)
        if not kids:
            _log("no audio output enabled: set play_to_speakers or virtual_mic in config")
            return False
        audio_procs[:] = kids
        _pumping = True
        epoch = _pump_epoch
    threading.Thread(target=_pump, args=(epoch,), daemon=True).start()
    return True


def stop_audio():
    global _pumping
    with audio_lock:
        _pumping = False
    _vmic_stop()
    for child in audio_procs:
        try:
            child.stdin.close()
        except Exception:
            pass
        try:
            child.terminate()
            child.wait(timeout=3)
        except Exception:
            try:
                child.kill()
            except Exception:
                pass
    audio_procs.clear()


def _route_guard():
    """Repair players that the audio policy re-routed off their target.

    WirePlumber / module-stream-restore has been observed moving our
    paplay stream onto the desktop's default output despite
    --device=phone-out, which leaves phone-mic silent and leaks the phone
    audio to the real speakers. Detect a mis-routed child (matched by PID
    to its sink-input) and restore the intended routing.
    """
    try:
        outs = subprocess.run(["pactl", "list", "sinks", "short"],
                              capture_output=True, text=True, timeout=3).stdout
        phone_idx = None
        for line in outs.splitlines():
            parts = line.split("\t")
            if len(parts) >= 2 and parts[1] == "phone-out":
                phone_idx = int(parts[0])
                break
        if phone_idx is None:
            return  # virtual mic not loaded; nothing to guard
        ins = subprocess.run(["pactl", "list", "sink-inputs"],
                             capture_output=True, text=True, timeout=3).stdout
        owner = {}  # client pid -> (sink_input_index, sink_index)
        blocks = re.findall(r"Sink Input #(\d+)\n(.*?)(?=\nSink Input #\d+\n|\Z)",
                            ins, re.S)
        for sid, body in blocks:
            m_sink = re.search(r"^\s*Sink:\s*(\d+)", body, re.M)
            m_pid = re.search(r'application\.process\.id\s*=\s*"?\d+', body)
            if m_sink and m_pid:
                owner.setdefault(int(re.search(r"\d+", m_pid.group(0)).group()),
                                 (int(sid), int(m_sink.group(1))))
        with audio_lock:
            kids = list(audio_procs)
        for child in kids:
            if child.poll() is not None:
                continue
            entry = owner.get(child.pid)
            if entry is not None and entry[1] != phone_idx:
                _log(f"player {child.pid} was re-routed to sink "
                     f"{entry[1]} (expected {phone_idx}); repairing")
                subprocess.run(["pactl", "move-sink-input", str(entry[0]),
                                str(phone_idx)],
                               capture_output=True, timeout=3)
    except Exception as exc:
        _log(f"route guard skipped: {exc}")


def _update_level(data):
    """Fold one s16le mono PCM chunk into the smoothed input level.

    Mapping: dBFS -60..-15 -> 0..1 so that (typical) close-mic speech sits
    clearly above room noise; display only, not for gain.
    """
    global _audio_level, _level_update
    try:
        samples = array.array("h")
        samples.frombytes(data[:len(data) // 2 * 2])
        if not samples:
            return
        rms = math.sqrt(sum(v * v for v in samples) / len(samples)) / 32768.0
        db = 20 * math.log10(rms) if rms > 0 else -90.0
        lvl = max(0.0, min(1.0, (db + 60.0) / 45.0))
        now = time.time()
        with _level_lock:
            prev = _audio_level
            coef = 0.45 if lvl >= prev else 0.15  # fast attack, slow release
            _audio_level = prev + (lvl - prev) * coef
            _level_update = now
    except Exception:
        pass


def _current_level():
    """Smoothed level with idle decay (used by the control socket)."""
    with _level_lock:
        lvl, upd = _audio_level, _level_update
    age = time.time() - upd
    if age > 0.5:
        lvl *= max(0.0, 1.0 - (age - 0.5))
    return max(0.0, min(1.0, lvl))


def _pump(epoch=None):
    """Read PCM from the host-side forward socket and pipe it to the player."""
    global _pcm_bytes, _pumping
    carry = b""
    while True:
        with audio_lock:
            pumping = _pumping and (epoch is None or epoch == _pump_epoch)
        if not pumping:
            break
        sock = None
        try:
            sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            sock.settimeout(5)
            sock.connect(b"\0" + HOST_SOCKET.encode())
            while True:
                with audio_lock:
                    children = _live_players(audio_procs)
                    pumping = _pumping and (epoch is None or epoch == _pump_epoch)
                if not pumping:
                    break
                if not children:
                    # No sink left to play into. Let the supervisor spawn
                    # fresh players instead of draining audio invisibly.
                    _log("no live audio players; pausing pump")
                    with audio_lock:
                        _pumping = False
                    break
                try:
                    data = sock.recv(4096)
                except (socket.timeout, OSError):
                    break
                if not data:
                    break
                _pcm_bytes += len(data)
                _update_level(data)
                chunk, carry = _even_chunk(carry, data)
                dropped = 0
                for child in children:
                    try:
                        fd = child.stdin.fileno()
                    except (AttributeError, OSError):
                        continue
                    written = _write_player(fd, chunk)
                    if written < len(chunk):
                        # Both player streams carry the same audio; report
                        # the shared loss once, not once per player.
                        dropped = max(dropped, len(chunk) - written)
                _note_dropped(dropped)
        except OSError:
            pass
        finally:
            if sock is not None:
                try:
                    sock.close()
                except OSError:
                    pass
        time.sleep(2)


def control_server():
    """Control Unix socket: status queries and restarts (single instance)."""
    try:
        if os.path.exists(CONTROL_SOCKET):
            os.unlink(CONTROL_SOCKET)
        srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        srv.bind(CONTROL_SOCKET)
        os.chmod(CONTROL_SOCKET, 0o600)
        srv.listen(4)
    except OSError as exc:
        _log(f"control socket unavailable: {exc}")
        return
    try:
        while running:
            try:
                srv.settimeout(1.0)
                conn, _addr = srv.accept()
            except socket.timeout:
                continue
            except OSError:
                break
            try:
                conn.settimeout(2.0)
                data = conn.recv(64)
                cmd = data.decode(errors="ignore").strip()
                if cmd == "status":
                    onl = device_online()
                    fwd = socket_forwarded()
                    resp = (f"device={int(onl)} forward={int(fwd)} "
                            f"audio_seconds={_pcm_bytes // 88200} "
                            f"dropped_seconds={_dropped_total // 88200}")
                    name = device_name() if onl else ""
                    if name:
                        resp += f" name={name}"
                elif cmd == "level":
                    resp = f"{_current_level():.3f}"
                elif cmd == "restart":
                    stop_audio()
                    ensure_forward()
                    start_audio()
                    resp = "restarted"
                else:
                    resp = "unknown"
                conn.sendall(resp.encode())
            except Exception:
                pass
            finally:
                try:
                    conn.close()
                except Exception:
                    pass
    finally:
        try:
            srv.close()
        except Exception:
            pass
        try:
            if os.path.exists(CONTROL_SOCKET):
                os.unlink(CONTROL_SOCKET)
        except OSError:
            pass


def _desktop_notify(body):
    """Best-effort desktop notification via notify-send."""
    try:
        subprocess.run(
            ["notify-send", "-i", "audio-input-microphone", "MicSource", body],
            capture_output=True, timeout=5,
        )
    except Exception:
        pass


_prev_state = None


def _notify_transition(state):
    """Send a desktop notification when the (online, forwarded) state changes."""
    global _prev_state
    if _prev_state is not None and state != _prev_state:
        online, forwarded = state
        if online and forwarded:
            _desktop_notify("Device connected — forwarding audio.")
        elif online:
            _desktop_notify("Device connected — waiting for forwarding.")
        else:
            _desktop_notify("Device disconnected.")
    _prev_state = state


def main_loop():
    _log("MicSource monitor starting")
    offline_ticks = 0
    last_bytes = 0
    stall_ticks = 0
    while running:
        try:
            # Pick up a device selection / wireless endpoint change without
            # needing a restart (the Flatpak app supervises this process).
            _load_config()
            online = device_online()
            forwarded = socket_forwarded() if online else False
            if online:
                offline_ticks = 0
                if not forwarded:
                    ensure_forward()
                    forwarded = socket_forwarded()
                start_audio()
                _route_guard()
                # If the forward is live but no audio arrives for ~20 s, the
                # phone app is wedged (e.g. after an APK replacement):
                # relaunch it so the recorder starts again.
                now_bytes = _pcm_bytes
                if forwarded and now_bytes == last_bytes:
                    stall_ticks += 1
                    if stall_ticks >= 4:
                        stall_ticks = 0
                        _log("no audio flowing; restarting the phone app")
                        start_device_service()
                else:
                    stall_ticks = 0
                last_bytes = now_bytes
            else:
                stop_audio()
                offline_ticks += 1
                # Try to launch the app on device at most once per ~30 s.
                if offline_ticks >= 6:
                    offline_ticks = 0
                    start_device_service()
            _notify_transition((online, forwarded))
        except Exception as exc:
            _log(f"loop error: {exc}")
        time.sleep(5)


def _run_once():
    """Foreground mode (--run): set up the forward, stream until Ctrl+C."""
    _load_config()
    ok, err = ensure_forward()
    if not ok:
        _log(f"could not set up socket forward: {err}")
        return 1
    if not start_audio():
        _log("no audio player found; cannot stream audio")
        return 1
    _log("forwarding until Ctrl+C…")
    try:
        while True:
            with audio_lock:
                procs = list(audio_procs)
                pumping = _pumping
            if not pumping:
                break
            if procs and all(c.poll() is not None for c in procs):
                _log("players exited; stopping")
                break
            time.sleep(1)
    except KeyboardInterrupt:
        pass
    stop_audio()
    _log("stopped")
    return 0


def main():
    global running
    # Make SIGTERM (systemctl stop, `micsource stop`) graceful so the
    # virtual mic modules are unloaded on shutdown.
    import signal

    def _catch(_sig, _frame):
        global running
        running = False

    signal.signal(signal.SIGTERM, _catch)
    signal.signal(signal.SIGINT, _catch)
    threading.Thread(target=control_server, daemon=True).start()
    _load_config()
    try:
        main_loop()
    except KeyboardInterrupt:
        running = False
    stop_audio()
    _log("MicSource monitor stopped")


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--run":
        raise SystemExit(_run_once())
    main()
