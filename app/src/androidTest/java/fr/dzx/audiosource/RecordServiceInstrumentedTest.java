package fr.dzx.audiosource;

import static androidx.test.platform.app.InstrumentationRegistry.getInstrumentation;
import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertNotNull;
import static org.junit.Assert.assertTrue;

import android.Manifest;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.content.ServiceConnection;
import android.os.IBinder;

import androidx.test.ext.junit.runners.AndroidJUnit4;
import androidx.test.rule.GrantPermissionRule;

import org.junit.After;
import org.junit.Before;
import org.junit.Rule;
import org.junit.Test;
import org.junit.runner.RunWith;

import java.util.concurrent.TimeUnit;

@RunWith(AndroidJUnit4.class)
public class RecordServiceInstrumentedTest {
    private static final long STATE_TIMEOUT_MS = 15_000;
    private static final long POLL_INTERVAL_MS = 200;

    @Rule
    public GrantPermissionRule grantPermissionRule =
            GrantPermissionRule.grant(Manifest.permission.RECORD_AUDIO);

    private Context context;
    private RecordService service;
    private boolean bound;

    private final ServiceConnection connection = new ServiceConnection() {
        @Override
        public void onServiceConnected(ComponentName name, android.os.IBinder binder) {
            service = ((RecordService.LocalBinder) binder).getService();
            bound = true;
        }

        @Override
        public void onServiceDisconnected(ComponentName name) {
            bound = false;
            service = null;
        }
    };

    @Before
    public void setUp() {
        context = getInstrumentation().getTargetContext();
        service = null;
        bound = false;
    }

    @After
    public void tearDown() {
        if (bound) {
            context.unbindService(connection);
            bound = false;
        }
        RecordService.stop(context);
    }

    private void bind() throws InterruptedException {
        Intent intent = new Intent(context, RecordService.class);
        assertTrue(context.bindService(intent, connection, Context.BIND_AUTO_CREATE));
        // Wait for onServiceConnected to set the service reference.
        long deadline = System.currentTimeMillis() + STATE_TIMEOUT_MS;
        while (!bound && System.currentTimeMillis() < deadline) {
            Thread.sleep(POLL_INTERVAL_MS);
        }
        assertNotNull(service);
    }

    private void waitForState(RecordService.State expected) throws InterruptedException {
        long deadline = System.currentTimeMillis() + STATE_TIMEOUT_MS;
        while (System.currentTimeMillis() < deadline) {
            if (service.getState() == expected) {
                return;
            }
            Thread.sleep(POLL_INTERVAL_MS);
        }
        assertEquals(expected, service.getState());
    }

    @Test
    public void initialStateIsStopped() throws Exception {
        bind();
        assertEquals(RecordService.State.STOPPED, service.getState());
    }

    @Test
    public void startServiceTransitionsToWaiting() throws Exception {
        bind();
        assertEquals(RecordService.State.STOPPED, service.getState());

        RecordService.start(context);
        waitForState(RecordService.State.WAITING);
    }

    @Test
    public void stopServiceTransitionsToStopped() throws Exception {
        bind();
        RecordService.start(context);
        waitForState(RecordService.State.WAITING);

        // Unbind so stopService can destroy the service.
        context.unbindService(connection);
        bound = false;
        service = null;

        RecordService.stop(context);

        // Poll via a fresh binding since the service object may be destroyed.
        bind();
        waitForState(RecordService.State.STOPPED);
    }

    @Test
    public void startStopIsIdempotent() throws Exception {
        bind();
        RecordService.start(context);
        waitForState(RecordService.State.WAITING);

        // Second start should not crash or duplicate the recorder thread.
        RecordService.start(context);
        waitForState(RecordService.State.WAITING);

        context.unbindService(connection);
        bound = false;
        service = null;

        RecordService.stop(context);

        bind();
        waitForState(RecordService.State.STOPPED);
    }
}
