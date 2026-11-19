#!/usr/bin/env python3
"""Pure-model tests for the StatusNotifierItem tray menu."""
import importlib.util
import os
import sys
import types
import unittest


REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
TRAY = os.path.join(REPO, "linux-install", "assets", "micsource-tray.py")


def load_tray():
    gi = types.ModuleType("gi")
    repository = types.ModuleType("gi.repository")
    gi.repository = repository
    gi.require_version = lambda *_args, **_kwargs: None
    for name in ("Gio", "GLib"):
        module = types.ModuleType(f"gi.repository.{name}")
        setattr(repository, name, module)
        sys.modules[f"gi.repository.{name}"] = module
    sys.modules["gi"] = gi
    sys.modules["gi.repository"] = repository
    spec = importlib.util.spec_from_file_location("micsource_tray_model", TRAY)
    tray = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(tray)
    return tray


class TrayModelTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tray = load_tray()

    def test_menu_config(self):
        items = self.tray.menu_config("connected")
        self.assertEqual([item["id"] for item in items], list(range(1, 8)))
        self.assertEqual(items[0]["label"], "Status: connected")
        self.assertFalse(items[0]["enabled"])
        self.assertEqual(items[1]["type"], "separator")
        self.assertEqual([item.get("action") for item in items[2:]],
                         ["start", "stop", "window", "config", "quit"])

    def test_dbusmenu_props(self):
        standard = self.tray.dbusmenu_props({
            "id": 3, "type": "standard", "label": "Start Service",
            "enabled": True})
        self.assertEqual(standard["label"], "Start Service")
        self.assertTrue(standard["enabled"])
        separator = self.tray.dbusmenu_props({"id": 2, "type": "separator"})
        self.assertEqual(separator["type"], "separator")
        self.assertNotIn("label", separator)

    def test_build_layout(self):
        revision, root = self.tray.build_layout(
            self.tray.menu_config("off"), 4)
        self.assertEqual(revision, 4)
        self.assertEqual(root[0], 0)
        self.assertEqual(root[1]["children-display"], "submenu")
        self.assertEqual([child[0] for child in root[2]], list(range(1, 8)))

    def test_group_properties_skips_unknown_ids(self):
        items = self.tray.menu_config("disconnected")
        found = self.tray.group_properties(items, [99, 3])
        self.assertIn(3, found)
        self.assertNotIn(99, found)
        self.assertEqual(found[3]["label"], "Start Service")

    def test_status_and_icon(self):
        self.assertEqual(self.tray.status_name(True), "connected")
        self.assertEqual(self.tray.tray_icon_name(True), "micsource")
        self.assertEqual(self.tray.tray_icon_name(False),
                         "audio-input-microphone")
        props = self.tray.sni_props(False)
        self.assertEqual(props["Category"], "ApplicationStatus")
        self.assertEqual(props["Id"], "micsource")
        self.assertEqual(props["Status"], "Active")
        self.assertEqual(props["WindowId"], 0)
        self.assertEqual(props["ToolTip"][0], "audio-input-microphone")


if __name__ == "__main__":
    unittest.main()
