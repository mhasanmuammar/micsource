package fr.dzx.audiosource;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertNull;

import org.junit.Before;
import org.junit.Test;

/**
 * Unit tests for the recording service's state management. These run on the
 * JVM without a device or emulator and cover the state transitions that
 * {@link RecordService} exposes through its public/package-private API, which
 * delegate to the already-tested {@link StateStore}.
 *
 * <p>{@link RecordService#onStartCommand} branches that construct
 * {@link AudioRecord}, query {@link android.content.Context}, or call
 * {@link android.app.Service#stopSelf} require Android framework mocking
 * (Robolectric) and are deliberately not covered here; they can be added once
 * a test device/emulator or Robolectric is available.
 */
public class RecordServiceTest {
    private RecordService service;

    @Before
    public void setUp() {
        service = new RecordService();
    }

    @Test
    public void initialStateIsStopped() {
        assertEquals(RecordService.State.STOPPED, service.getState());
    }

    @Test
    public void setStateListenerReceivesCurrentStateOnSubscribe() {
        final RecordService.State[] seen = {null};
        service.setStateListener(state -> seen[0] = state);

        assertEquals(RecordService.State.STOPPED, seen[0]);
    }

    @Test
    public void publishStateNotifiesListenerAndUpdatesStore() {
        final RecordService.State[] seen = {null};
        service.setStateListener(state -> seen[0] = state);

        service.publishState(RecordService.State.WAITING);

        assertEquals(RecordService.State.WAITING, seen[0]);
        assertEquals(RecordService.State.WAITING, service.getState());
    }

    @Test
    public void lateListenerReceivesCurrentStateOnSubscribe() {
        service.publishState(RecordService.State.STREAMING);

        final RecordService.State[] seen = {null};
        service.setStateListener(state -> seen[0] = state);

        assertEquals(RecordService.State.STREAMING, seen[0]);
        assertEquals(RecordService.State.STREAMING, service.getState());
    }

    @Test
    public void stopAfterFailurePublishesError() {
        final RecordService.State[] seen = {null};
        service.setStateListener(state -> seen[0] = state);

        service.stopAfterFailure();

        assertEquals(RecordService.State.ERROR, seen[0]);
        assertEquals(RecordService.State.ERROR, service.getState());
    }

    @Test
    public void clearingListenerStopsNotifications() {
        final RecordService.State[] seen = {null};
        service.setStateListener(state -> seen[0] = state);
        service.setStateListener(null);
        seen[0] = null;

        service.publishState(RecordService.State.ERROR);

        assertNull(seen[0]);
        assertEquals(RecordService.State.ERROR, service.getState());
    }

    @Test
    public void stateTransitionsThroughAllStates() {
        final RecordService.State[] seen = {null};
        service.setStateListener(state -> seen[0] = state);

        service.publishState(RecordService.State.PERMISSION_NEEDED);
        assertEquals(RecordService.State.PERMISSION_NEEDED, seen[0]);

        service.publishState(RecordService.State.WAITING);
        assertEquals(RecordService.State.WAITING, seen[0]);

        service.publishState(RecordService.State.STREAMING);
        assertEquals(RecordService.State.STREAMING, seen[0]);

        service.publishState(RecordService.State.ERROR);
        assertEquals(RecordService.State.ERROR, seen[0]);

        service.publishState(RecordService.State.STOPPED);
        assertEquals(RecordService.State.STOPPED, seen[0]);
        assertEquals(RecordService.State.STOPPED, service.getState());
    }
}
