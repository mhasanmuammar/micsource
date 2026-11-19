#!/usr/bin/env python3
"""Stub-backed tests for the MicSource wireless ADB CLI workflow."""

import os
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
CLI = ROOT / "linux-install/assets/micsource"


class WirelessCliTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="micsource-wireless-")
        self.home = Path(self.temp.name)
        self.data = self.home / ".local/share/micsource"
        self.config_dir = self.home / ".config/micsource"
        self.data.mkdir(parents=True)
        self.config_dir.mkdir(parents=True)
        self.stub = self.home / "adb-stub"
        self.stub.write_text("""#!/bin/bash
set -eu
printf 'ARGS=%s\\n' "$*"
case " $* " in
  *' pair '*) cat >"$PAIR_INPUT_LOG"; echo 'Successfully paired';;
  *' devices -l '*) printf 'List of devices attached\\n192.168.1.20:38000 device product:test model:Phone\\n';;
  *' connect '*) echo 'connected to 192.168.1.20:38000';;
  *' mdns services '*) printf 'phone _adb-tls-connect._tcp 192.168.1.20:38000\\n';;
esac
""")
        self.stub.chmod(0o755)
        (self.config_dir / "config.ini").write_text(
            f"[adb]\nadb_path = {self.stub}\nserver_port = 5042\n"
            "\n[device]\nserial =\n")
        self.pair_input = self.home / "pair-stdin"
        self.adb_log = self.home / "adb.log"

    def tearDown(self):
        self.temp.cleanup()

    def run_cli(self, *args, input_text=None):
        env = os.environ.copy()
        env.update({
            "HOME": str(self.home),
            "PAIR_INPUT_LOG": str(self.pair_input),
            "ADB_CALL_LOG": str(self.adb_log),
        })
        return subprocess.run(
            ["bash", str(CLI), *args], env=env, input=input_text,
            capture_output=True, text=True, timeout=10)

    def test_pair_code_is_stdin_and_not_an_adb_argument(self):
        result = self.run_cli("wireless-pair", "192.168.1.20:41000",
                              input_text="123456\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.pair_input.read_text(), "123456\n")
        self.assertIn("ARGS=-P 5042 pair 192.168.1.20:41000", result.stdout)
        self.assertNotIn("123456", result.stdout + result.stderr)

    def test_pair_rejects_invalid_code_before_adb(self):
        result = self.run_cli("wireless-pair", "192.168.1.20:41000",
                              input_text="12x\n")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("six digits", result.stderr)
        self.assertFalse(self.pair_input.exists())

    def test_wireless_connect_selects_serial_and_forwards_audio_socket(self):
        result = self.run_cli("wireless-connect", "192.168.1.20:38000")
        self.assertEqual(result.returncode, 0, result.stderr)
        config = (self.config_dir / "config.ini").read_text()
        self.assertIn("serial = 192.168.1.20:38000", config)
        self.assertIn("ARGS=-P 5042 connect 192.168.1.20:38000", result.stdout)
        self.assertIn("ARGS=-P 5042 -s 192.168.1.20:38000 forward localabstract:micsource localabstract:audiosource",
                      result.stdout)

    def test_device_listing_and_mdns_use_micsource_server(self):
        result = self.run_cli("devices")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("ARGS=-P 5042 devices -l", result.stdout)
        discovery = self.run_cli("wireless-discover")
        self.assertEqual(discovery.returncode, 0, discovery.stderr)
        self.assertIn("ARGS=-P 5042 mdns services", discovery.stdout)


if __name__ == "__main__":
    unittest.main()
