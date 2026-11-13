# Pure D-Bus Tray Implementation Plan

> **Status (2026-11-13): fully superseded and reverted — do not implement.**
> This plan was implemented (commits `021d1aa`, `e2ccb1b`, `94a9890`), but the
> pure-D-Bus tray failed at startup with `'DBusConnection' object has no
> attribute 'own_name'`. By user decision on 2026-11-13 the deployed tray/app
> were rolled back to the AppIndicator versions and
> `linux-install/assets/` was re-seeded from that rollback (commit `0417ea7`);
> `linux-install/tests/test_tray_model.py` was deleted with the reverted code
> (commit `67af9c6`). The plan's commits remain in git history, but **no part
> of this plan describes shipped behavior**. The installer work it referenced
> became asset seeding instead — see
> `../specs/2026-11-07-installer-assets-design.md`.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the tray's Gtk-3/AppIndicator client with a pure GLib/Gio
`org.kde.StatusNotifierItem` + `com.canonical.dbusmenu` implementation, so
the tray needs zero host packages.

**Architecture:** One Python daemon (`micsource-tray.py`) exports the SNI
object and a dbusmenu server on the session bus, registers with
`org.kde.StatusNotifierWatcher` (and re-registers when it restarts), and
keeps the existing adb-polling worker thread. The app's prefs toggle
preflights "watcher on the bus?" instead of "bindings imported?".

**Tech Stack:** Python 3 stdlib + PyGObject (`GLib`, `Gio` only). Tests:
stdlib `unittest` with a fake-`gi` stub (the sandbox has no gi).

**Spec:** `linux-install/docs/superpowers/specs/2026-11-03-pure-dbus-tray-design.md`

## Global Constraints

- The deployed files (`~/.local/share/micsource/*`) are the source of
  truth; installer heredocs are spliced from them and must remain
  **byte-identical** (verify with the splice-verify snippet in Task 4).
  *(Historical constraint, superseded: the repo assets are now the source of
  truth; see the status note above.)*
- No new host dependencies: stdlib + `python3-gi` (`GLib`/`Gio`) only.
- English UI strings; no destructive commands.
- Tray icon id / app id stays `micsource`; object paths:
  `/StatusNotifierItem` (SNI) and `/StatusNotifierItem/menus/micsource`
  (dbusmenu).
- After every task: `python3 -m py_compile` the touched files; at the end
  splice + verify + commit.

## Review Focus

- **Watcher restart while the tray runs** → the tray must re-register and
  keep serving (no crash, icon reappears). Tested: user-side manual step
  in Task 2 Step 7; code-level via `_watch_watcher()` unit check in Task
  1's stub run (signals wired, no exception).
- **Menu Event with unknown / disabled ids** (`clicked` on id 2 or 99) →
  ignored silently, no traceback in the journal. Tested: unit test
  `test_event_dispatch_ignores_disabled_and_unknown`.
- **GetGroupProperties/GetProperty for ids not in the model** → return
  only the found properties, empty for missing ids, no crash. Tested:
  `test_get_group_properties_missing_ids`.
- **Icon not resolvable by name** → SNI also carries a ToolTip and falls
  back to `audio-input-microphone`; the icon never blocks menu actions.
  Covered by user-side manual step in Task 2 Step 7.
- **adb missing / phone offline while the tray runs** → poll thread keeps
  ticking, icon flips to disconnected, no thread errors. Covered by
  user-side manual step in Task 2 Step 7.

---

### Task 1: Pure menu/property model in `micsource-tray.py`

**Files:**
- Modify: `~/.local/share/micsource/micsource-tray.py` (top half: replace
  the gi-import block and add pure-model functions; keep `_load_config`,
  `run_adb`, `device_online`, `socket_forwarded`, `start_monitoring`,
  `stop_monitoring` as-is for Task 2)
- Create: `linux-install/tests/test_tray_model.py`

**Interfaces (Produces — Task 2 consumes exactly these):**
- `menu_config(status: str) -> list[dict]` — items `{"id": int,
  "type": "standard"|"separator", "label": str (standard only),
  "enabled": bool, "action": str (start|stop|window|config|quit)}`; ids
  1..7 in the order Status / separator / Start / Stop / Open Control
  Window / Open Config Folder / Quit.
- `dbusmenu_props(item: dict) -> dict[str, object]` — keys subset of
  `{"type", "label", "enabled", "visible", "children-display"}`; plain
  Python values only (no GLib).
- `build_layout(items: list[dict], revision: int) -> tuple` — returns
  `(revision, (0, {"children-display": "submenu"}, child_tuple))` where
  each child is `(id, dbusmenu_props(item), ())` and separators carry no
  `label` key.
- `status_name(connected: bool) -> str` — `"connected"` / `"disconnected"`.
- `tray_icon_name(connected: bool) -> str` — `"micsource"`,
  else `"audio-input-microphone"`.
- `sni_props(connected: bool) -> dict[str, object]` — keys
  `{"Category", "Id", "Title", "Status", "WindowId", "IconName",
  "ToolTip"}` with `Category="ApplicationStatus"`, `Id="micsource"`,
  `Title="MicSource"`, `Status="Active"`, `WindowId=0`,
  `ToolTip={"icon_name": <icon>, "icon_pixmap": [], "title": "MicSource",
  "description": <status line>}`.
- `variant_for(value: object) -> GLib.Variant` — glue (str/bool/int/l-
  ist/tuple-dict), NOT unit-tested (needs real GLib).

- [ ] **Step 1: Write the failing test** — `linux-install/tests/
  test_tray_model.py`, stdlib unittest, loads the deployed tray file with
  a fake-`gi` stub before import so the module imports without PyGObject:

```python
import importlib.util, os, sys, types, unittest

TRAY = os.path.expanduser("~/.local/share/micsource/micsource-tray.py")

def _load():
    gi = types.ModuleType("gi")
    gi.require_version = lambda *a, **k: None
    repo = types.ModuleType("gi.repository")
    for name in ("GLib", "Gio"):
        mod = types.ModuleType(f"gi.repository.{name}")
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
        self.assertEqual(items[2]["type"], "separator")
        self.assertEqual(
            [i.get("action") for i in items[2:]],
            [None, "start", "stop", "window", "config", "quit"])
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
        self.assertEqual(std["children-display"] if "children-display" in std
                         else None, None)

    def test_build_layout(self):
        _rev, root = self.t.build_layout(self.t.menu_config("off"), 4)
        self.assertEqual(_rev, 4)
        self.assertEqual(root[0], 0)
        self.assertEqual(root[1]["children-display"], "submenu")
        self.assertEqual([c[0] for c in root[2]], [1, 2, 3, 4, 5, 6, 7])

    def test_get_group_properties_missing_ids(self):
        items = self.t.menu_config("disconnected")
        found = self.t.group_properties(items, [99, 3])
        self.assertIn(3, found)     # found: {"id": 3, "props": {...}}
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
```

- [ ] **Step 2: Run the test, verify it fails**

Run: `python3 linux-install/tests/test_tray_model.py -v`
Expected: FAIL (AttributeError: module has no `menu_config`).

- [ ] **Step 3: Implement the pure model in `micsource-tray.py`**

Replace the module docstring + import block: docstring describes the pure
SNI daemon; imports become:
```python
import configparser, os, socket, subprocess, threading, time
from gi.repository import GLib, Gio
```
(keep the old `except`-path tray.log message but with the new, simpler
import failure text: "PyGObject (GLib/Gio) not available"; no exec, exit
1). Then add the pure functions exactly as specified in **Interfaces**
(marks as "pure, no gi — unit-tested"): a static `STATUS_LABEL = …` line
`f"Status: {status}"`, `group_properties(items, ids) -> dict[int, dict]`
(helper used by both `GetGroupProperties` and tests), and the constants
`SNI_PATH = "/StatusNotifierItem"`,
`SNI_MENU_PATH = "/StatusNotifierItem/menus/micsource"`.

- [ ] **Step 4: Run the test, verify it passes**

Run: `python3 linux-install/tests/test_tray_model.py -v`
Expected: PASS (all 5).

- [ ] **Step 5: Commit**

```bash
git add linux-install/tests/test_tray_model.py
git commit -m "test: pure tray menu model (fake-gi runnable)"
```
(Do NOT splice the tray into install.sh yet — Task 2 completes the file.)

---

### Task 2: GLib/Gio SNI daemon wiring

**Files:**
- Modify: `~/.local/share/micsource/micsource-tray.py` (replace
  `update_indicator`, `_apply_status`, `_build_menu`, `main` and the
  Gtk-3 menu boilerplate with the daemon; poll/adb helpers from Task 1
  stay).

**Interfaces:**
- Consumes: Task 1's pure model + the kept adb helpers.
- Produces (Task 3 uses only): the process semantics — exits 0 while
  running, 1 when no StatusNotifier watcher is on the bus (message also
  appended to `~/.local/share/micsource/tray.log`). The app probe in
  Task 3 relies on that.

- [ ] **Step 1: Implement `TrayDaemon`**

Class with exactly these methods:
- `__init__(self, bus)` — session `Gio.DBusConnection`; `self.revision
  = 1`; `self.connected = False`; objects registered lazily in `run()`.
- `export_all(self)` — `bus.register_object` for `/StatusNotifierItem`
  and `/StatusNotifierItem/menus/micsource`, with method-call and
  property-get callbacks dispatching on interface name. The introspection
  XML carries the full SNI interface (Category, Id, Title, Status,
  WindowId, IconName, IconPixmap, OverlayIconName, AttentionIconName,
  AttentionIconPixmap, ToolTip `(sa(iiay)ss)`, Menu `o`, ItemIsMenu `b`;
  methods Activate/SecondaryActivate/ContextMenu/Scroll as no-ops) and
  the full `com.canonical.dbusmenu` interface with properties
  Version(u)=3 / TextDirection="ltr" / Status="normal" /
  IconThemePath=[] and methods GetLayout, GetGroupProperties,
  GetProperty, AboutToShow, Event, EventGroup plus signals
  ItemsPropertiesUpdated, LayoutUpdated, ItemActivationRequested.
- `register_with_watcher(self) -> bool` —
  `bus.call_sync("org.kde.StatusNotifierWatcher", "/StatusNotifierWatcher",
  "org.kde.StatusNotifierWatcher", "RegisterStatusNotifierItem",
  GLib.Variant("(s)", (bus.get_unique_name(),)), …)`; True on success.
- `watch_watcher(self)` — subscribe `g_signals` to
  `org.freedesktop.DBus.NameOwnerChanged` from `org.freedesktop.DBus` for
  name `org.kde.StatusNotifierWatcher`; on `new_owner != ""` and not the
  first fire, call `register_with_watcher()` again (log outcome).
- `apply_status(self, connected: bool) -> None` — recompute
  `sni_props(menu_config status)`, `self.revision += 1`; emit
  `LayoutUpdated(revision, 0)` + `ItemsPropertiesUpdated` + SNI
  `NewToolTip`/`NewIcon`/`NewStatus` signals from the bus.
- `_dispatch_action(self, action: str) -> None` — start/stop →
  `subprocess.Popen([CLI_PATH, "start"|"stop"])`; window → spawn
  `micsource-app.py`; config → `xdg-open CONFIG_DIR`; quit →
  `self.loop.quit()`.
- `run(self) -> None` — `export_all()`, `watch_watcher()`,
  `register_with_watcher()` (failure → tray.log line + `raise
  SystemExit(1)`), poll timer `GLib.timeout_add_seconds(3, _poll_status)`
  (same worker-thread pattern as before, calling `GLib.idle_add(daemon.
  apply_status, connected)`), then `GLib.MainLoop().run()` in
  `self.loop`.
- `main()`: `_load_config()`, `Gio.bus_get_sync(SESSION)`, open daemon,
  `daemon.run()`. argv is accepted and ignored (`--tray` tolerated).

**Variants (`variant_for` glue mapping):** str → `(s,)`, bool → `(b,)`,
int → `(i,)`, list → `(as,)` of strings, dict per key (ToolTip uses
`(sa(iiay)ss)` with empty pixmap array; layout props `(sv)`); menu
layout uses the exact dbusmenu spec types.

- [ ] **Step 2: Syntax + import check**

Run:
```bash
python3 -m py_compile ~/.local/share/micsource/micsource-tray.py
python3 linux-install/tests/test_tray_model.py -v
```
Expected: compile OK; tests still PASS (the model is untouched).

- [ ] **Step 3: Interactive smoke (you, GNOME session)**

```bash
pkill -f micsource-tray.py 2>/dev/null; true
~/.local/share/micsource/micsource tray
sleep 1; pgrep -af micsource-tray.py
journalctl --user -o cat --since "-1 min" | grep -i micsource
```
Expected: process alive, no traceback; icon appears in the panel.

- [ ] **Step 4: Commit**

```bash
git add linux-install/docs/superpowers/plans 2>/dev/null || true
git commit -m "feat: pure GLib/Gio StatusNotifierItem tray daemon"
```
(empty diff note: deployed file is outside the repo; final splice in
Task 4 brings it in.)

---

### Task 3: Prefs toggle preflight → D-Bus watcher probe

**Files:**
- Modify: `~/.local/share/micsource/micsource-app.py`:
  - replace `TRAY_PROBE + _tray_bindings_ok()` with `_tray_watcher_ok()`
    (same subprocess pattern, new probe),
  - delete `_tray_display_hint()` and its call site,
  - update `_apply_tray(False-branch)` failure text.

**Interfaces:**
- Consumes: Task 2's exit-code contract (process exit 1 ⇔ no watcher;
  but the app doesn't spawn to probe — it asks D-Bus itself).
- Produces: `_tray_watcher_ok(self) -> bool` — True iff
  `org.kde.StatusNotifierWatcher` has an owner on the session bus.

- [ ] **Step 1: Implement the probe**

Replace `TRAY_PROBE` with (exact):
```python
    TRAY_PROBE = (
        "from gi.repository import Gio\n"
        "from gi.repository import GLib\n"
        "bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)\n"
        "answer = bus.call_sync(\n"
        "    'org.freedesktop.DBus', '/org/freedesktop/DBus',\n"
        "    'org.freedesktop.DBus.NameHasOwner',\n"
        "    GLib.Variant('(s)', ('org.kde.StatusNotifierWatcher',)),\n"
        "    None, Gio.DBusCallFlags.NONE, 3000, None)\n"
        "raise SystemExit(0 if answer.unpack()[0] else 3)\n")
```
`_tray_watcher_ok()` = same body as `_tray_bindings_ok()` (subprocess
`[sys.executable, "-c", self.TRAY_PROBE]`, rc == 0). `_apply_tray(True)`
preflight failure text becomes exactly:
`"no tray support on this desktop — no StatusNotifier watcher on the "
"session bus (GNOME needs the appindicatorsupport shell extension)"`.
Drop the `hint` variable and `_tray_display_hint` entirely.

- [ ] **Step 2: Verify**

Run: `python3 -m py_compile ~/.local/share/micsource/micsource-app.py`
Expected: OK.

- [ ] **Step 3: Commit (repo side arrives with Task 4 splice)**

```bash
git add linux-install/tests  # ensure tests dir tracked
git commit --allow-empty -m "chore: tray preflight switched to D-Bus watcher probe"
```

---

### Task 4: Installer splice + docs

> **Superseded on 2026-11-07, then made obsolete by the 2026-11-13 revert.**
> The installer-splice half became asset seeding: the deployed tray/app were
> copied into `linux-install/assets/` by the asset-based installer work
> (`../specs/2026-11-07-installer-assets-design.md`). The tray/app content
> itself was reverted to AppIndicator (see the status note at the top of this
> plan), so `test_tray_model.py` and the pure-D-Bus splice below no longer
> exist. Do not execute these steps.

**Files:**
- Modify: `linux-install/install.sh` — splice tray + app heredocs from
  the deployed files; update `step_tray` text (no more gir packages; the
  tray needs only PyGObject), the `--with-tray` offer wording, and the
  `launch_tray` comment if it mentions bindings.
- Modify: `linux-install/README.md` tray mentions (the two gir packages
  disappear; desktops keep the watcher note), `docs/USER.md`
  troubleshooting row (rewrite the three-pieces text: only a
  StatusNotifier-capable shell is required; errors in
  `~/.local/share/micsource/tray.log`), `docs/AGENT.md` tray section
  (protocol instead of bindings; pure model function list; `register_
  with_watcher`/`watch_watcher`; preflight via NameHasOwner; probe text).

**Interfaces:**
- Consumes: deployed `micsource-tray.py` (Task 1+2 result) and
  `micsource-app.py` (Task 3 result) as splice sources.

- [ ] **Step 1: Splice both heredocs**

```python
import re
src = open('linux-install/install.sh', encoding='utf-8').read()
for path, marker in (
    ('/home/hasan/.local/share/micsource/micsource-tray.py', 'TRAY'),
    ('/home/hasan/.local/share/micsource/micsource-app.py', 'APP')):
    body = open(path, encoding='utf-8').read().rstrip('\n')
    pat = re.compile(r"(cat > \"\$\{%s_PATH\}\" <<'__%sEOF__'\n).*?(\\n__%sEOF__\\n)"
                     % (marker, marker, marker), re.S)
    src, n = pat.subn(lambda m: m.group(1) + body + m.group(2), src, count=1)
    assert n == 1, marker
open('linux-install/install.sh', 'w', encoding='utf-8').write(src)
```

- [ ] **Step 2: Verify**

Run:
```bash
bash -n linux-install/install.sh
python3 -m py_compile ~/.local/share/micsource/micsource-app.py
                      ~/.local/share/micsource/micsource-tray.py
python3 linux-install/tests/test_tray_model.py -v
python3 - <<'PY'
import re
src = open('linux-install/install.sh', encoding='utf-8').read()
for var, dep in (('APP_PATH', 'micsource-app.py'), ('TRAY_PATH', 'micsource-tray.py')):
    body = re.search(r"cat > \"\$\{%s\}\" <<'__\w*EOF__'\n(.*?)\n__\w*EOF__\n" % var, src, re.S).group(1)
    deployed = open('/home/hasan/.local/share/micsource/' + dep, encoding='utf-8').read()
    assert body == deployed.rstrip('\n'), dep
print('BYTE-IDENTICAL')
PY
```
Expected: all OK / PASS / `BYTE-IDENTICAL`.

- [ ] **Step 3: Docs updates + commit**

Rewrite the tray reel in `docs/AGENT.md` ("## Tray script" section: pure
D-Bus SNI daemon, pure model function list, preflight via NameHasOwner,
watcher-restart behavior, tray.log on no-watcher), the USER.md
troubleshooting row, README tray mentions. Commit:

```bash
git add linux-install
git commit -m "feat: tray speaks StatusNotifierItem over pure Gio; drop GTK-3 bindings"
```

---

## Self-Review

- Spec coverage: registration/re-register (T2), dbusmenu server (T2),
  poll thread reuse (T2), no-watcher exit path (T2), toggle preflight
  (T3), installer/docs (T4) — all mapped.
- Step scan: every step writes one thing (test → fail → implement →
  pass → commit) or names the exact string/command.
- Type consistency: `menu_config`/`dbusmenu_props`/`build_layout`/
  `group_properties`/`sni_props` names match across Tasks 1–2 and the
  tests; Task 3 consumes only exit semantics.
- Proportion: plan ≈ code scale; no full bodies except where the spec
  pins exact strings (XML fields, probe, messages are short data).
