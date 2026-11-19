package fr.dzx.audiosource;

import static androidx.test.platform.app.InstrumentationRegistry.getInstrumentation;
import static org.junit.Assert.assertArrayEquals;
import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertNotNull;

import android.Manifest;
import android.content.Context;

import androidx.test.ext.junit.rules.ActivityScenarioRule;
import androidx.test.ext.junit.runners.AndroidJUnit4;
import androidx.test.rule.GrantPermissionRule;

import org.junit.Before;
import org.junit.Rule;
import org.junit.Test;
import org.junit.runner.RunWith;

@RunWith(AndroidJUnit4.class)
public class MainActivityInstrumentedTest {
    @Rule
    public ActivityScenarioRule<MainActivity> scenarioRule =
            new ActivityScenarioRule<>(MainActivity.class);

    @Rule
    public GrantPermissionRule grantPermissionRule =
            GrantPermissionRule.grant(Manifest.permission.RECORD_AUDIO);

    private Context context;

    @Before
    public void setUp() {
        context = getInstrumentation().getTargetContext();
    }

    // --- state -> label mapping -------------------------------------------

    @Test
    public void stateLabelMapsEveryServiceState() {
        assertEquals(R.string.state_stopped,
                MainActivity.stateLabel(RecordService.State.STOPPED, true));
        assertEquals(R.string.state_waiting,
                MainActivity.stateLabel(RecordService.State.WAITING, true));
        assertEquals(R.string.state_streaming,
                MainActivity.stateLabel(RecordService.State.STREAMING, true));
        assertEquals(R.string.state_error,
                MainActivity.stateLabel(RecordService.State.ERROR, true));
        assertEquals(R.string.state_permission_needed,
                MainActivity.stateLabel(RecordService.State.PERMISSION_NEEDED, true));
    }

    @Test
    public void stateLabelForcesPermissionNeededWithoutMicrophone() {
        assertEquals(R.string.state_permission_needed,
                MainActivity.stateLabel(RecordService.State.STOPPED, false));
        assertEquals(R.string.state_permission_needed,
                MainActivity.stateLabel(RecordService.State.STREAMING, false));
    }

    // --- permission request selection -------------------------------------

    @Test
    public void permissionsToRequestEmptyWhenAllGranted() {
        assertArrayEquals(new String[0],
                MainActivity.permissionsToRequest(true, true, true));
    }

    @Test
    public void permissionsToRequestMicrophoneOnlyWhenMissing() {
        assertArrayEquals(new String[]{Manifest.permission.RECORD_AUDIO},
                MainActivity.permissionsToRequest(false, true, true));
    }

    @Test
    public void permissionsToRequestNotificationsOnlyWhenMissing() {
        assertArrayEquals(new String[]{Manifest.permission.POST_NOTIFICATIONS},
                MainActivity.permissionsToRequest(true, false, true));
    }

    @Test
    public void permissionsToRequestBothWhenBothMissing() {
        assertArrayEquals(
                new String[]{Manifest.permission.RECORD_AUDIO,
                        Manifest.permission.POST_NOTIFICATIONS},
                MainActivity.permissionsToRequest(false, false, true));
    }

    @Test
    public void permissionsToRequestIgnoresNotificationsBeforeAndroid13() {
        assertArrayEquals(new String[0],
                MainActivity.permissionsToRequest(true, false, false));
        assertArrayEquals(new String[]{Manifest.permission.RECORD_AUDIO},
                MainActivity.permissionsToRequest(false, false, false));
    }

    // --- activity lifecycle ----------------------------------------------

    @Test
    public void activityLaunchesWithoutCrashing() {
        // ActivityScenarioRule already launched the activity; simply verify
        // the context is available (activity is in RESUMED/CREATED state).
        assertNotNull(context);
    }
}
