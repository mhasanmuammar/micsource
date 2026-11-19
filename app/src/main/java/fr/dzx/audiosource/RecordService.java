package fr.dzx.audiosource;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.Manifest;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.content.pm.ServiceInfo;
import android.media.AudioFormat;
import android.media.AudioRecord;
import android.media.MediaRecorder;
import android.os.Build;
import android.os.Binder;
import android.os.IBinder;
import android.util.Log;

import androidx.core.app.NotificationCompat;
import androidx.core.app.NotificationManagerCompat;
import androidx.core.content.ContextCompat;

import java.util.Objects;

public class RecordService extends Service {
    private static final String ACTION_RECORD = "fr.dzx.audiosource.RECORD";
    private static final String ACTION_STOP = "fr.dzx.audiosource.STOP";

    private static final String CHANNEL_ID = "audiosource";
    private static final int NOTIFICATION_ID = 1;

    private static final int DEFAULT_SAMPLE_RATE = 44100;
    private static final int DEFAULT_CHANNEL_CONFIG = AudioFormat.CHANNEL_IN_MONO;
    private static final int DEFAULT_AUDIO_ENCODING = AudioFormat.ENCODING_PCM_16BIT;

    private Thread recorderThread;
    private final LocalBinder binder = new LocalBinder();
    private final StateStore store = new StateStore();

    public enum State { STOPPED, PERMISSION_NEEDED, WAITING, STREAMING, ERROR }

    public interface StateListener { void onStateChanged(State state); }

    public class LocalBinder extends Binder {
        RecordService getService() { return RecordService.this; }
    }

    public State getState() { return store.get(); }

    public void setStateListener(StateListener listener) {
        store.setListener(listener);
    }

    void publishState(State next) {
        store.publish(next);
    }

    void stopAfterFailure() {
        publishState(State.ERROR);
    }

    public static void start(Context context) {
        Intent intent = new Intent(context, RecordService.class).setAction(ACTION_RECORD);
        ContextCompat.startForegroundService(context, intent);
    }

    public static void stop(Context context) {
        context.stopService(new Intent(context, RecordService.class));
    }

    @Override
    public void onCreate() {
        super.onCreate();

        Notification notification = createNotificationStarting();

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            NotificationChannel channel = new NotificationChannel(CHANNEL_ID,
                    getString(R.string.app_name), NotificationManager.IMPORTANCE_LOW);
            getNotificationManager().createNotificationChannel(channel);
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            startForeground(NOTIFICATION_ID, notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE);
        } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(NOTIFICATION_ID, notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_NONE);
        } else {
            startForeground(NOTIFICATION_ID, notification);
        }
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        if (intent != null && Objects.equals(intent.getAction(), ACTION_STOP)) {
            stopSelf();
            return START_NOT_STICKY;
        }

        if (recorderThread != null && recorderThread.isAlive()) {
            return START_NOT_STICKY;
        }

        if (ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO)
                != PackageManager.PERMISSION_GRANTED) {
            publishState(State.PERMISSION_NEEDED);
            stopSelf();
            return START_NOT_STICKY;
        }

        int minBufSize = AudioRecord.getMinBufferSize(
                DEFAULT_SAMPLE_RATE,
                DEFAULT_CHANNEL_CONFIG,
                DEFAULT_AUDIO_ENCODING);

        if (minBufSize <= 0) {
            Log.e(App.TAG, "AudioRecord returned invalid minimum buffer size: " + minBufSize);
            stopAfterFailure();
            return START_NOT_STICKY;
        }

        AudioRecord recorder;
        try {
            recorder = new AudioRecord(
                    MediaRecorder.AudioSource.DEFAULT,
                    DEFAULT_SAMPLE_RATE,
                    DEFAULT_CHANNEL_CONFIG,
                    DEFAULT_AUDIO_ENCODING,
                    2 * minBufSize);
        } catch (IllegalArgumentException | SecurityException failure) {
            Log.e(App.TAG, "Failed to construct AudioRecord", failure);
            stopAfterFailure();
            return START_NOT_STICKY;
        }

        if (recorder.getState() != AudioRecord.STATE_INITIALIZED) {
			Log.e(App.TAG, "Failed to initialize AudioRecord with default parameters");
			publishState(State.ERROR);
            recorder.release();
            return START_NOT_STICKY;
        }

        recorderThread = new RecordThread(this, recorder);
        recorderThread.start();

        return START_NOT_STICKY;
    }

    @Override
    public IBinder onBind(Intent intent) {
        return binder;
    }

    @Override
    public void onDestroy() {
        publishState(State.STOPPED);
        if (recorderThread != null) {
            recorderThread.interrupt();

            try {
                recorderThread.join();
            } catch (InterruptedException e) {
                Log.e(App.TAG, "RecordThread.join", e);
            }

            recorderThread = null;
        }

        stopForeground(true);
    }

    protected void showNotificationListening() {
        publishState(State.WAITING);
        Notification notification = new NotificationCompat.Builder(this, CHANNEL_ID)
                .addAction(createStopAction())
                .setContentTitle(getString(R.string.app_name))
                .setContentText(getText(R.string.notification_waiting))
                .setSmallIcon(R.drawable.ic_microphone)
                .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
                .build();
        getNotificationManager().notify(NOTIFICATION_ID, notification);
    }

    protected void showNotificationEstablished() {
        publishState(State.STREAMING);
        Notification notification = new NotificationCompat.Builder(this, CHANNEL_ID)
                .addAction(createStopAction())
                .setColor(ContextCompat.getColor(this, R.color.ic_launcher_background))
                .setContentTitle(getString(R.string.app_name))
                .setContentText(getText(R.string.notification_forwarding))
                .setSmallIcon(R.drawable.ic_microphone)
                .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
                .build();
        getNotificationManager().notify(NOTIFICATION_ID, notification);
    }

    private NotificationManagerCompat getNotificationManager() {
        return NotificationManagerCompat.from(this);
    }

    private Notification createNotificationStarting() {
        return new NotificationCompat.Builder(this, CHANNEL_ID)
                .setContentTitle(getString(R.string.app_name))
                .setContentText(getText(R.string.notification_starting))
                .setSmallIcon(R.drawable.ic_microphone)
                .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
                .build();
    }

    private Intent createStopIntent() {
        return new Intent(this, RecordService.class)
                .setAction(ACTION_STOP);
    }

    private NotificationCompat.Action createStopAction() {
        Intent stopIntent = createStopIntent();
        PendingIntent stopPendingIntent = PendingIntent.getService(this, 0, stopIntent,
                PendingIntent.FLAG_ONE_SHOT | PendingIntent.FLAG_IMMUTABLE);
        String stopString = getString(R.string.action_stop);
        NotificationCompat.Action.Builder actionBuilder = new NotificationCompat.Action.Builder(0
                , stopString, stopPendingIntent);
        return actionBuilder.build();
    }
}
