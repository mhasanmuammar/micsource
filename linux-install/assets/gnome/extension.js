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
// Status is polled through the micsource CLI (async subprocess, no adb
// socket poking from the shell main loop).
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import GObject from 'gi://GObject';
import { Extension } from 'resource:///org/gnome/shell/extensions/extension.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as PopupMenu from 'resource:///org/gnome/shell/ui/popupMenu.js';
import * as QuickSettings from 'resource:///org/gnome/shell/ui/quickSettings.js';

const SERVICE = 'micsource.service';

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
        this._svc = null;           // systemd unit state (may be null)
        this._ext = ext;            // exposes the fast re-poll

        // Clicking the pill toggles the service; the chevron opens the
        // menu. A fast re-poll grounds `checked` in the real state.
        this.connect('clicked', () => this._toggleService());
    }

    _refreshSoon() {
        if (this._ext && this._ext._refreshNext) {
            this._ext._refreshNext();
        }
    }

    // Called by the extension with a parsed CLI `status` output.
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
        try {
            const active = this._monitoring || this._svc === 'active';
            const verb = active ? 'stop' : 'start';
            const cli = GLib.build_filenamev([GLib.get_home_dir(),
                '.local', 'share', 'micsource', 'micsource']);
            log('MicSource: pill click -> service ' + verb);
            Gio.Subprocess.new([cli, verb], Gio.SubprocessFlags.NONE);
        } catch (e) {
            console.error(`MicSource: toggle failed: ${e}`);
        }
        // ~1 s re-poll grounds the pill in the real service state
        this._refreshSoon();
    }

    _openWindow() {
        const cli = GLib.build_filenamev([GLib.get_home_dir(),
            '.local', 'share', 'micsource', 'micsource']);
        try {
            Gio.Subprocess.new([cli, 'window'], Gio.SubprocessFlags.NONE);
        } catch (e) {
            console.error(`MicSource: open window failed: ${e}`);
        }
    }

    destroy() {
        super.destroy();
    }
});

export default class MicSourceExtension extends Extension {
    enable() {
        this._cancellable = new Gio.Cancellable();

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
        if (this._soon) {
            GLib.source_remove(this._soon);
        }
        this._soon = GLib.timeout_add(GLib.PRIORITY_DEFAULT, 1200, () => {
            this._soon = null;
            this._refresh();
            return GLib.SOURCE_REMOVE;
        });
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

    _refresh() {
        const cli = GLib.build_filenamev([GLib.get_home_dir(),
            '.local', 'share', 'micsource', 'micsource']);
        this._spawnGet([cli, 'status'], (out) => {
            let svc = null;
            let device = false;
            let monitoring = false;

            const m = out.match(/monitor:\s*device=(\d+)\s+forward=/);
            if (m) { monitoring = true; device = m[1] === '1'; }

            const s = out.match(/systemd unit:\s*([A-Za-z-]+)/);
            if (s) svc = s[1];

            const d = out.match(/adb device state:\s*([A-Za-z]+)/);
            if (d) device = device || d[1].toLowerCase() === 'device';

            // Device model reported by the monitor (name=Pixel 8).
            const nm = out.match(/monitor:[^\n]*\bname=([^\n\r]+)/);
            const name = nm ? nm[1].trim() : '';

            if (this._toggle && !this._cancellable.is_cancelled()) {
                this._toggle.apply(svc, device, monitoring, name);
            }
        });
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
