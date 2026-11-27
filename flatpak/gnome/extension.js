// MicSource quick-settings pill (GNOME Shell 45+ ES module).
// Default-export Extension subclass: GNOME Shell loads extensions by
// instantiating the module's default export (function-form enable/disable
// raises 'extensionModule.default is not a constructor' on modern Shell).
//
// Design (GNOME Quick Settings / GSConnect pattern):
//   * pill = QuickSettings.QuickMenuToggle with a live status subtitle
//   * pill click = start/stop the background service
//   * pill chevron = expandable menu with Device + Monitoring status
//     rows (same information as the control window) and actions.
//
// The control window owns the monitor in the Flatpak sandbox, so the
// extension talks to it over D-Bus.  When no D-Bus name is present (a host
// install that has not started the app yet) it falls back to the CLI.
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import GObject from 'gi://GObject';
import { Extension } from 'resource:///org/gnome/shell/extensions/extension.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as PopupMenu from 'resource:///org/gnome/shell/ui/popupMenu.js';
import * as QuickSettings from 'resource:///org/gnome/shell/ui/quickSettings.js';

const BUS_NAME = 'io.github.mhasanmuammar.MicSource';
const OBJECT_PATH = '/io/github/mhasanmuammar/MicSource';
const CONTROL_IFACE = BUS_NAME + '.Control';
const CLI = GLib.build_filenamev([GLib.get_home_dir(), '.local', 'share',
    'micsource', 'micsource']);

const MicSourceToggle = GObject.registerClass({
    GTypeName: 'MicSourceToggle',
}, class MicSourceToggle extends QuickSettings.QuickMenuToggle {
    _init(ext) {
        this._ext = ext;            // stored before super._init
        super._init({
            title: 'MicSource',
            subtitle: 'checking…',
            // Plain mic icon in both states: the -muted variant carries an
            // x-badge that visually misaligns the pill icon. State is
            // conveyed by the subtitle text and the checked accent colour.
            iconName: 'audio-input-microphone-symbolic',
            // checked is driven by apply() from the real service state, so
            // a failed click can never briefly lie (accent flicker).
            toggleMode: false,
        });

        // Expanded menu: same two status lines as the control window,
        // then the same actions (HIG: quick settings menu = header +
        // rows + actions).
        this.menu.setHeader('audio-input-microphone-symbolic',
            'MicSource', 'phone mic over USB');

        this._deviceItem = new PopupMenu.PopupMenuItem('Device: —',
            { reactive: false });
        this._monItem = new PopupMenu.PopupMenuItem('Monitoring: —',
            { reactive: false });
        this.menu.addMenuItem(this._deviceItem);
        this.menu.addMenuItem(this._monItem);
        this.menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem());

        this._svcItem = new PopupMenu.PopupMenuItem('Start Service');
        this._svcItem.connect('activate', () => this._toggleService());
        this.menu.addMenuItem(this._svcItem);

        const winItem = new PopupMenu.PopupMenuItem('Open Control Window');
        winItem.connect('activate', () => this._openWindow());
        this.menu.addMenuItem(winItem);

        // Some shell point releases / themes indent the quick-toggle
        // subtitle; pin it to the left edge to match the title. The
        // subtitle label lives on the *inner* QuickToggle (since GNOME 45
        // QuickMenuToggle wraps one instead of subclassing it, so there
        // is no this._subtitle on ourselves — the direct access crashed
        // _init on GNOME 51). Climb the one level of widgets the shell
        // owns; optional chaining keeps _init safe even if the shell
        // re-lays out its internals again.
        const innerToggle = this._box?.get_first_child();
        this._subtitle = innerToggle?._subtitle ?? null;
        this._subtitle?.set_style('text-align: left; padding-left: 0;');

        this._monitoring = false;   // monitor answered "status"
        this._device = false;       // phone link seen
        this._svc = null;           // service state (may be null)
        this._name = '';
        this._ext = ext;            // exposes the fast re-poll

        // Clicking the pill toggles the service; the chevron opens the
        // menu. A fast re-poll grounds `checked` in the real state.
        this.connect('clicked', () => this._toggleService());
    }

    _refreshSoon() {
        if (this._ext && this._ext._refreshNext)
            this._ext._refreshNext();
    }

    // Called by the extension with a status snapshot.
    apply(svc, device, monitoring, name) {
        this._svc = svc;
        this._device = device;
        this._monitoring = monitoring;
        this._name = name || '';

        const svcActive = svc === 'active';
        // Pill state + look (audio muted icon mirrors the app's Start
        // button sensitivity: service running = mic available).
        // checked gives the pill the active accent colour while the
        // monitoring/service is running (GNOME .quick-toggle:checked style)
        this.checked = monitoring || svcActive;

        // Title spec:
        //   off                    -> "Service — off"
        //   on + connected phone   -> device model name
        //   on + no phone          -> "Disconnected"
        //   service coming up      -> "starting…"
        if (!monitoring && !svcActive)
            this.subtitle = 'Service — off';
        else if (monitoring && device)
            this.subtitle = this._name || 'on · phone connected';
        else if (monitoring)
            this.subtitle = 'Disconnected';
        else
            this.subtitle = 'starting…';

        // Menu rows (mirror the control window's status rows).
        if (this._deviceItem.label)
            this._deviceItem.label.text =
                'Device: ' + (device
                    ? (this._name || 'connected') : 'disconnected');
        if (this._monItem.label)
            this._monItem.label.text =
                'Monitoring: ' + (monitoring
                    ? (device
                        ? ('on — streaming' +
                           (this._name ? ' · ' + this._name : ''))
                        : 'on — waiting')
                    : (svcActive ? 'starting…' : 'off'));
        if (this._svcItem.label)
            this._svcItem.label.text = svcActive
                ? 'Stop Service' : 'Start Service';
    }

    _toggleService() {
        const active = this._monitoring || this._svc === 'active';
        const verb = active ? 'stop' : 'start';
        log('MicSource: pill click -> service ' + verb);
        this._ext._serviceAction(verb);
        // ~1 s re-poll grounds the pill in the real service state
        this._refreshSoon();
    }

    _openWindow() {
        this._ext._showWindow();
    }

    destroy() {
        super.destroy();
    }
});

export default class MicSourceExtension extends Extension {
    enable() {
        this._cancellable = new Gio.Cancellable();
        this._refreshing = false;

        this._toggle = new MicSourceToggle(this);
        const indicator = new QuickSettings.SystemIndicator();
        indicator.quickSettingsItems.push(this._toggle);
        this._indicator = indicator;
        // External indicators (pill-only, no top-bar icon) are registered
        // through quickSettings on every shell this API exists on;
        // Main.panel.addToStatusArea() would throw "Status indicator must
        // be an instance of PanelMenu.Button".
        Main.panel.statusArea.quickSettings.addExternalIndicator(
            this._indicator);

        this._timer = GLib.timeout_add_seconds(GLib.PRIORITY_DEFAULT, 4,
            () => {
                this._refresh();
                return GLib.SOURCE_CONTINUE;
            });
        this._refresh();
    }

    // fast, deduplicated re-poll after a user action (pill click etc.)
    _refreshNext() {
        if (this._soon)
            GLib.source_remove(this._soon);
        this._soon = GLib.timeout_add(GLib.PRIORITY_DEFAULT, 1200, () => {
            this._soon = null;
            this._refresh();
            return GLib.SOURCE_REMOVE;
        });
    }

    // Call the app's Control interface.  `callback(result)` receives the
    // GLib.Variant reply or null; status polls use NO_AUTO_START so the
    // shell never spawns a background app just to paint the pill.
    _dbusCall(method, params, flags, callback) {
        try {
            Gio.DBus.session.call(
                BUS_NAME, OBJECT_PATH, CONTROL_IFACE, method, params,
                null, flags, 3000, this._cancellable,
                (connection, res) => {
                    if (!this._cancellable ||
                        this._cancellable.is_cancelled())
                        return;
                    try {
                        callback(connection.call_finish(res));
                    } catch (e) {
                        callback(null);
                    }
                });
        } catch (e) {
            console.error(`MicSource: D-Bus ${method} failed: ${e}`);
            callback(null);
        }
    }

    _applyStatus(status) {
        const svc = typeof status.service === 'string'
            ? status.service : null;
        const device = !!status.device;
        const monitoring = !!status.monitoring;
        const name = typeof status.name === 'string' ? status.name : '';
        if (this._toggle && !this._cancellable.is_cancelled())
            this._toggle.apply(svc, device, monitoring, name);
    }

    _refresh() {
        if (this._refreshing)
            return;
        this._refreshing = true;
        this._dbusCall('GetStatus', null, Gio.DBusCallFlags.NO_AUTO_START,
            (result) => {
                this._refreshing = false;
                if (!result) {
                    this._refreshFromCli();
                    return;
                }
                try {
                    const [status] = result.deepUnpack();
                    this._applyStatus(status || {});
                } catch (e) {
                    console.error(`MicSource: bad status reply: ${e}`);
                    this._refreshFromCli();
                }
            });
    }

    // Host fallback: query the installed CLI when the app is not running.
    _refreshFromCli() {
        this._spawnGet([CLI, 'status'], (out) => {
            let svc = null;
            let device = false;
            let monitoring = false;

            const m = out.match(/monitor:\s*device=(\d+)\s+forward=/);
            if (m) { monitoring = true; device = m[1] === '1'; }

            const s = out.match(/systemd unit:\s*([A-Za-z-]+)/);
            if (s) svc = s[1];

            const d = out.match(/adb device state:\s*([A-Za-z]+)/);
            if (d) device = device || d[1].toLowerCase() === 'device';

            const nm = out.match(/monitor:[^\n]*\bname=([^\n\r]+)/);
            const name = nm ? nm[1].trim() : '';

            if (this._toggle && !this._cancellable.is_cancelled())
                this._toggle.apply(svc, device, monitoring, name);
        });
    }

    _serviceAction(verb) {
        const method = verb === 'stop' ? 'Stop' : 'Start';
        this._dbusCall(method, null, Gio.DBusCallFlags.NONE, (result) => {
            if (!result)
                this._spawn([CLI, verb]);
        });
    }

    _showWindow() {
        this._dbusCall('ShowWindow', null, Gio.DBusCallFlags.NONE,
            (result) => {
                if (!result)
                    this._spawn([CLI, 'window']);
            });
    }

    _spawn(argv) {
        try {
            Gio.Subprocess.new(argv, Gio.SubprocessFlags.NONE);
        } catch (e) {
            console.error(`MicSource: spawn ${argv[0]} failed: ${e}`);
        }
    }

    _spawnGet(argv, callback) {
        try {
            const proc = Gio.Subprocess.new(argv,
                Gio.SubprocessFlags.STDOUT_PIPE |
                Gio.SubprocessFlags.STDERR_PIPE);
            proc.communicate_utf8_async(null, this._cancellable,
            (procObj, res) => {
                if (!this._cancellable || this._cancellable.is_cancelled())
                    return;
                try {
                    const [, out, err] =
                        procObj.communicate_utf8_finish(res);
                    callback((out || '') + (err || ''));
                } catch (e) {
                    callback('');
                }
            });
        } catch (e) {
            console.error(`MicSource: spawn failed: ${e}`);
            callback('');
        }
    }

    disable() {
        if (this._cancellable) {
            this._cancellable.cancel();
            this._cancellable = null;
        }
        if (this._timer) {
            GLib.source_remove(this._timer);
            this._timer = null;
        }
        if (this._soon) {
            GLib.source_remove(this._soon);
            this._soon = null;
        }
        if (this._toggle) {
            this._toggle.destroy();
            this._toggle = null;
        }
        if (this._indicator) {
            this._indicator.destroy();
            this._indicator = null;
        }
    }
}
