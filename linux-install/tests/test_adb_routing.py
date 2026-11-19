#!/usr/bin/env python3
"""Tests for MicSource's isolated ADB command construction."""
import os
import sys
import unittest


ASSETS = os.path.join(os.path.dirname(os.path.dirname(__file__)), "assets")
sys.path.insert(0, ASSETS)

from micsource_adb import (  # noqa: E402
    DEFAULT_SERVER_PORT,
    command,
    server_port_error,
    validate_server_port,
)


class AdbRoutingTest(unittest.TestCase):
    def test_default_uses_private_server_port(self):
        self.assertEqual(DEFAULT_SERVER_PORT, 5038)
        self.assertEqual(
            command("/opt/micsource/adb", DEFAULT_SERVER_PORT, ["devices"]),
            ["/opt/micsource/adb", "-P", "5038", "devices"],
        )

    def test_override_preserves_global_option_order_and_serial(self):
        self.assertEqual(
            command("/usr/bin/adb", "5042", ["forward", "--list"], "phone-1"),
            ["/usr/bin/adb", "-P", "5042", "-s", "phone-1", "forward", "--list"],
        )

    def test_system_default_port_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "reserved"):
            validate_server_port("5037")

    def test_server_bind_failure_names_micsource_port(self):
        message = server_port_error(5038, "cannot bind tcp:localhost:5038: address already in use")
        self.assertIn("MicSource ADB server port 5038 is unavailable", message)
        self.assertEqual(server_port_error(5038, "device offline"), "")

    def test_invalid_ports_are_rejected(self):
        for value in ("not-a-port", "1023", "65536", ""):
            with self.subTest(value=value):
                with self.assertRaises(ValueError):
                    validate_server_port(value)


if __name__ == "__main__":
    unittest.main()
