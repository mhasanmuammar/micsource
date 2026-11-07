# Pure tray menu-model tests (stdlib only; runs where PyGObject is absent).
# The tray module imports `gi` at module scope, so a fake-`gi` stub is
# injected BEFORE import — the pure model itself uses no gi.
import importlib.util
import os
import sys
import types
import unittest

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
TRAY = os.path.join(REPO, "linux-install", "assets", "micsource-tray.py")


def _load():
    gi = types.ModuleType("gi")
    gi.require_version = lambda *a, **k: None
    repo = types.ModuleType("gi.repository")
    for name in ("GLib", "Gio"):
        mod = types.ModuleType("gi.repository." + name)
        setattr(repo, name, mod)
        sys.modules["gi.repository." + name] = mod
    gi.repository = repo
    sys.modules.setdefault("gi", gi)
    sys.modules.setdefault("gi.repository", repo)
    spec = importlib.util.spec_from_file_location("micsource_tray", TRAY)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class TrayModelTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.t = _load()

    def test_menu_config(self):
        items = self.t.menu_config("connected")
        self.assertEqual([i["id"] for i in items], [1, 2, 3, 4, 5, 6, 7])
        self.assertEqual(items[0]["label"], "Status: connected")
        self.assertFalse(items[0]["enabled"])
        self.assertEqual(items[1]["type"], "separator")
        self.assertEqual(
            [i.get("action") for i in items[2:]],
            ["start", "stop", "window", "config", "quit"])
        self.assertTrue(all(i.get("enabled", True) for i in items[2:]))

    def test_dbusmenu_props(self):
        std = self.t.dbusmenu_props({"id": 3, "type": "standard",
                                     "label": "Start Service",
                                     "enabled": True})
        self.assertEqual(std["label"], "Start Service")
        self.assertTrue(std["enabled"])
        sep = self.t.dbusmenu_props({"id": 2, "type": "separator"})
        self.assertEqual(sep["type"], "separator")
        self.assertNotIn("label", sep)
        self.assertIsNone(std.get("children-display"))

    def test_build_layout(self):
        _rev, root = self.t.build_layout(self.t.menu_config("off"), 4)
        self.assertEqual(_rev, 4)
        self.assertEqual(root[0], 0)
        self.assertEqual(root[1]["children-display"], "submenu")
        self.assertEqual([c[0] for c in root[2]], [1, 2, 3, 4, 5, 6, 7])

    def test_group_properties_missing_ids(self):
        items = self.t.menu_config("disconnected")
        found = self.t.group_properties(items, [99, 3])
        self.assertIn(3, found)
        self.assertNotIn(99, found)
        self.assertEqual(found[3]["label"], "Start Service")

    def test_status_and_icon(self):
        self.assertEqual(self.t.status_name(True), "connected")
        self.assertEqual(self.t.tray_icon_name(True), "micsource")
        self.assertEqual(self.t.tray_icon_name(False),
                         "audio-input-microphone")
        props = self.t.sni_props(False)
        self.assertEqual(props["Category"], "ApplicationStatus")
        self.assertEqual(props["Id"], "micsource")
        self.assertEqual(props["Status"], "Active")
        self.assertEqual(props["WindowId"], 0)
        self.assertEqual(props["ToolTip"]["icon_name"],
                         "audio-input-microphone")


if __name__ == "__main__":
    unittest.main()
