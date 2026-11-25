// MicSource extension preferences (no options for now; GNOME 45+ API).
import Adw from 'gi://Adw';
import { ExtensionPreferences } from 'resource:///org/gnome/Shell/Extensions/js/extensions/prefs.js';

export default class MicSourcePrefs extends ExtensionPreferences {
    fillPreferencesWindow(window) {
        const page = new Adw.PreferencesPage();
        const group = new Adw.PreferencesGroup({ title: 'MicSource' });
        const row = new Adw.ActionRow({
            title: 'No preferences yet',
            subtitle: 'Edit ~/.config/micsource/config.ini instead',
        });
        group.add(row);
        page.add(group);
        window.add(page);
    }
}
