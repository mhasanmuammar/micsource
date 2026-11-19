package fr.dzx.audiosource;

import android.Manifest;
import android.app.Activity;
import android.content.ComponentName;
import android.content.Intent;
import android.content.ServiceConnection;
import android.content.pm.PackageManager;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.IBinder;
import android.provider.Settings;
import android.view.View;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;

import androidx.core.app.ActivityCompat;
import androidx.core.content.ContextCompat;

public class MainActivity extends Activity {
    private static final int REQUEST_PERMISSIONS = 7;
    private TextView statusView;
    private TextView permissionView;
    private RecordService service;
    private boolean bound;
    private boolean startAfterPermission;

    private final ServiceConnection serviceConnection = new ServiceConnection() {
        @Override
        public void onServiceConnected(ComponentName name, IBinder binder) {
            service = ((RecordService.LocalBinder) binder).getService();
            service.setStateListener(state -> runOnUiThread(() -> showState(state)));
            bound = true;
            showState(service.getState());
        }

        @Override
        public void onServiceDisconnected(ComponentName name) {
            bound = false;
            service = null;
            showState(RecordService.State.STOPPED);
        }
    };

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        buildScreen();
        updatePermissions();
        bindService(new Intent(this, RecordService.class), serviceConnection, BIND_AUTO_CREATE);
    }

    @Override
    protected void onDestroy() {
        if (bound) {
            service.setStateListener(null);
            unbindService(serviceConnection);
            bound = false;
        }
        super.onDestroy();
    }

    private void buildScreen() {
        int pad = (int) (24 * getResources().getDisplayMetrics().density);
        LinearLayout content = new LinearLayout(this);
        content.setOrientation(LinearLayout.VERTICAL);
        content.setPadding(pad, pad, pad, pad);

        TextView title = new TextView(this);
        title.setText(R.string.app_name);
        title.setTextSize(28);
        title.setTypeface(null, android.graphics.Typeface.BOLD);
        content.addView(title);

        TextView intro = new TextView(this);
        intro.setText(R.string.phone_intro);
        intro.setTextSize(16);
        content.addView(intro, spaced());

        statusView = new TextView(this);
        statusView.setTextSize(19);
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.KITKAT) {
            statusView.setAccessibilityLiveRegion(View.ACCESSIBILITY_LIVE_REGION_POLITE);
        }
        content.addView(statusView, spaced());

        permissionView = new TextView(this);
        permissionView.setTextSize(14);
        content.addView(permissionView, spaced());

        Button permissions = new Button(this);
        permissions.setText(R.string.action_permissions);
        permissions.setOnClickListener(v -> requestMissingPermissions(false));
        content.addView(permissions, spaced());

        LinearLayout controls = new LinearLayout(this);
        controls.setOrientation(LinearLayout.HORIZONTAL);
        Button start = new Button(this);
        start.setText(R.string.action_start);
        start.setOnClickListener(v -> requestMissingPermissions(true));
        controls.addView(start, new LinearLayout.LayoutParams(0, -2, 1));
        Button stop = new Button(this);
        stop.setText(R.string.action_stop);
        stop.setOnClickListener(v -> RecordService.stop(this));
        controls.addView(stop, new LinearLayout.LayoutParams(0, -2, 1));
        content.addView(controls, spaced());

        TextView wirelessTitle = new TextView(this);
        wirelessTitle.setText(R.string.wireless_title);
        wirelessTitle.setTextSize(20);
        wirelessTitle.setTypeface(null, android.graphics.Typeface.BOLD);
        content.addView(wirelessTitle, spaced());
        TextView wirelessHelp = new TextView(this);
        wirelessHelp.setText(Build.VERSION.SDK_INT >= Build.VERSION_CODES.R
                ? R.string.wireless_help_supported : R.string.wireless_help_usb);
        wirelessHelp.setTextSize(15);
        content.addView(wirelessHelp, spaced());
        Button developer = new Button(this);
        developer.setText(R.string.action_developer_options);
        developer.setOnClickListener(v -> openDeveloperOptions());
        content.addView(developer, spaced());

        ScrollView scroll = new ScrollView(this);
        scroll.addView(content);
        setContentView(scroll);
    }

    private LinearLayout.LayoutParams spaced() {
        LinearLayout.LayoutParams params = new LinearLayout.LayoutParams(-1, -2);
        params.topMargin = (int) (12 * getResources().getDisplayMetrics().density);
        return params;
    }

    private void requestMissingPermissions(boolean startWhenGranted) {
        boolean microphoneGranted = hasMicrophonePermission();
        boolean notificationsGranted = Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU
                && ContextCompat.checkSelfPermission(this,
                Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED;
        boolean notificationsSupported = Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU;

        String[] requested = permissionsToRequest(microphoneGranted, notificationsGranted,
                notificationsSupported);

        if (requested.length == 0) {
            if (startWhenGranted) RecordService.start(this);
            updatePermissions();
            return;
        }

        startAfterPermission = startWhenGranted;
        ActivityCompat.requestPermissions(this, requested, REQUEST_PERMISSIONS);
    }

    /** Permissions still needed before recording may start (empty = none). */
    static String[] permissionsToRequest(boolean microphoneGranted, boolean notificationsGranted,
            boolean notificationsSupported) {
        boolean needMicrophone = !microphoneGranted;
        boolean needNotifications = notificationsSupported && !notificationsGranted;
        if (needMicrophone && needNotifications) {
            return new String[]{Manifest.permission.RECORD_AUDIO,
                    Manifest.permission.POST_NOTIFICATIONS};
        }
        if (needMicrophone) return new String[]{Manifest.permission.RECORD_AUDIO};
        if (needNotifications) return new String[]{Manifest.permission.POST_NOTIFICATIONS};
        return new String[0];
    }

    @Override
    public void onRequestPermissionsResult(int requestCode, String[] permissions, int[] grantResults) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults);
        if (requestCode != REQUEST_PERMISSIONS) return;
        boolean start = startAfterPermission;
        startAfterPermission = false;
        updatePermissions();
        if (start && hasMicrophonePermission()) RecordService.start(this);
        else if (start) showState(RecordService.State.PERMISSION_NEEDED);
        else showState(service == null ? RecordService.State.STOPPED : service.getState());
    }

    private boolean hasMicrophonePermission() {
        return ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO)
                == PackageManager.PERMISSION_GRANTED;
    }

    private void updatePermissions() {
        if (permissionView == null) return;
        String microphone = hasMicrophonePermission() ? getString(R.string.permission_mic_granted)
                : getString(R.string.permission_mic_needed);
        String notifications = Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU
                || ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS)
                == PackageManager.PERMISSION_GRANTED
                ? getString(R.string.permission_notifications_granted)
                : getString(R.string.permission_notifications_needed);
        permissionView.setText(getString(R.string.permissions_status, microphone, notifications));
    }

    private void showState(RecordService.State state) {
        if (statusView == null) return;
        int label = stateLabel(state, hasMicrophonePermission());
        statusView.setText(getString(R.string.state_format, getString(label)));
    }

    /** Label for a service state; without microphone permission the
     * permission-needed label always wins. */
    static int stateLabel(RecordService.State state, boolean microphoneGranted) {
        if (!microphoneGranted) return R.string.state_permission_needed;
        switch (state) {
            case WAITING: return R.string.state_waiting;
            case STREAMING: return R.string.state_streaming;
            case ERROR: return R.string.state_error;
            case PERMISSION_NEEDED: return R.string.state_permission_needed;
            default: return R.string.state_stopped;
        }
    }

    private void openDeveloperOptions() {
        Intent intent = new Intent(Settings.ACTION_APPLICATION_DEVELOPMENT_SETTINGS);
        try {
            startActivity(intent);
        } catch (Exception unavailable) {
            try {
                startActivity(new Intent(Settings.ACTION_SETTINGS));
            } catch (Exception ignored) {
                startActivity(new Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                        Uri.parse("package:" + getPackageName())));
            }
        }
    }
}
