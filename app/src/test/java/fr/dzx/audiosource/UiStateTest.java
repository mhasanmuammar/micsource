package fr.dzx.audiosource;

import static org.junit.Assert.assertArrayEquals;
import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;

import android.Manifest;

import org.junit.Test;

/**
 * Unit tests for the phone GUI's state presentation and permission-request
 * logic (pure helpers used by MainActivity).
 */
public class UiStateTest {

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
        // notifications unsupported (pre-Android 13) and not granted
        assertArrayEquals(new String[0],
                MainActivity.permissionsToRequest(true, false, false));
        assertArrayEquals(new String[]{Manifest.permission.RECORD_AUDIO},
                MainActivity.permissionsToRequest(false, false, false));
    }

    // --- host-triggered auto-start ----------------------------------------

    @Test
    public void wantsStartRequiresTheIntentFlagAndMicrophonePermission() {
        assertTrue(MainActivity.wantsStart(true, true));
        assertFalse(MainActivity.wantsStart(true, false));
        assertFalse(MainActivity.wantsStart(false, true));
        assertFalse(MainActivity.wantsStart(false, false));
    }
}
