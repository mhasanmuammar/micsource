#!/usr/bin/env python3
"""Regression tests for the MicSource audio pump's latency bound.

The player pipe used to be the kernel default (64 KiB = ~740 ms of PCM).
A bursty Wi-Fi stream filled it once and, because the input rate equals the
playback rate, it never drained: every later sample played ~0.6 s late.
These tests pin the latency governor that keeps the queue small by dropping
the surplus instead of accepting permanent delay.
"""
import importlib.util
import os
import sys
import unittest
from pathlib import Path

ASSETS = Path(__file__).resolve().parents[1] / "assets"
sys.path.insert(0, str(ASSETS))

MONITOR = ASSETS / "micsource-monitor.py"


def load_monitor():
    spec = importlib.util.spec_from_file_location("micsource_monitor_test", MONITOR)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class FakeProc:
    def __init__(self, alive=True):
        self._alive = alive

    def poll(self):
        return None if self._alive else 1


class PlayerQueueTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.mod = load_monitor()

    def setUp(self):
        self.read_fd, self.write_fd = os.pipe()
        os.set_blocking(self.write_fd, False)

    def tearDown(self):
        os.close(self.read_fd)
        os.close(self.write_fd)

    def occupancy(self):
        return self.mod._pipe_occupancy(self.write_fd)

    def test_pipe_size_is_capped_at_the_latency_budget(self):
        self.mod._set_player_pipe_size(self.write_fd)
        self.assertLessEqual(
            self.mod.fcntl.fcntl(self.write_fd, self.mod.F_GETPIPE_SZ),
            self.mod.PLAYER_PIPE_BYTES,
        )
        self.assertLessEqual(self.mod.PLAYER_PIPE_BYTES, 16384)

    def test_write_is_refused_when_it_would_exceed_the_budget(self):
        budget = self.mod.PLAYER_PIPE_BYTES
        os.write(self.write_fd, b"\x01\x02" * (budget // 2))
        self.assertEqual(self.occupancy(), budget)
        # Any further chunk would queue stale audio: drop it, don't block.
        self.assertEqual(self.mod._write_player(self.write_fd, b"\x03\x04" * 100), 0)
        self.assertEqual(self.occupancy(), budget)
        # Once the player consumed the queue, fresh audio is accepted again.
        self.assertEqual(len(os.read(self.read_fd, budget)), budget)
        self.assertEqual(self.mod._write_player(self.write_fd, b"\x05\x06" * 100), 200)

    def test_early_burst_writes_the_fitting_prefix_only(self):
        budget = self.mod.PLAYER_PIPE_BYTES
        os.write(self.write_fd, b"\x00" * (budget - 1000))
        accepted = self.mod._write_player(self.write_fd, b"\x11\x22" * 1500)
        self.assertEqual(accepted, 1000)  # only the free space, even
        self.assertEqual(accepted % 2, 0)
        self.assertEqual(self.occupancy(), budget)

    def test_failed_pipe_size_does_not_break_playback(self):
        # Admission control alone must bound the queue if the kernel refuses
        # to shrink the pipe (e.g. when it already holds more than the cap).
        os.write(self.write_fd, b"\x00" * (self.mod.PLAYER_PIPE_BYTES + 4000))
        self.mod._set_player_pipe_size(self.write_fd)
        self.assertEqual(self.mod._write_player(self.write_fd, b"\x00" * 200), 0)

    def test_even_chunks_carry_the_odd_byte(self):
        chunk, carry = self.mod._even_chunk(b"", b"\x01\x02\x03")
        self.assertEqual(chunk, b"\x01\x02")
        self.assertEqual(carry, b"\x03")
        chunk, carry = self.mod._even_chunk(carry, b"\x04\x05")
        self.assertEqual(chunk, b"\x03\x04")
        self.assertEqual(carry, b"\x05")
        chunk, carry = self.mod._even_chunk(carry, b"")
        self.assertEqual(chunk, b"")
        self.assertEqual(carry, b"\x05")


class PlayerLifecycleTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.mod = load_monitor()

    def test_live_players_excludes_exited_children(self):
        live = FakeProc(alive=True)
        dead = FakeProc(alive=False)
        self.assertEqual(self.mod._live_players([dead, live]), [live])
        self.assertEqual(self.mod._live_players([dead]), [])

    def test_start_audio_replaces_a_pump_whose_players_all_exited(self):
        dead = FakeProc(alive=False)
        spawned = []

        class FakeThread:
            def __init__(self, *args, **kwargs):
                pass

            def start(self):
                pass

        old = (self.mod._pumping, self.mod.audio_procs,
               self.mod._spawn_player, self.mod._vmic_start,
               self.mod._vmic_enabled, self.mod._speakers_enabled,
               self.mod._vm_ok, self.mod.threading.Thread)
        try:
            self.mod._pumping = True
            self.mod.audio_procs = [dead]
            self.mod._spawn_player = lambda *a, **k: spawned.append((a, k)) or FakeProc(alive=True)
            self.mod._vmic_start = lambda: True
            self.mod._vmic_enabled = lambda: True
            self.mod._speakers_enabled = lambda: False
            self.mod._vm_ok = True
            self.mod.threading.Thread = FakeThread
            self.assertTrue(self.mod.start_audio())
            self.assertEqual(len(spawned), 1)
            self.assertEqual(len(self.mod.audio_procs), 1)
        finally:
            (self.mod._pumping, self.mod.audio_procs,
             self.mod._spawn_player, self.mod._vmic_start,
             self.mod._vmic_enabled, self.mod._speakers_enabled,
             self.mod._vm_ok, self.mod.threading.Thread) = old


if __name__ == "__main__":
    unittest.main()
