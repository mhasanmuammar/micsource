package fr.dzx.audiosource;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertNull;

import org.junit.Before;
import org.junit.Test;

/**
 * Unit tests for the service's UI state holder. StateStore backs
 * RecordService's state field and listener fan-out, so these tests cover the
 * service state semantics without an Android runtime.
 */
public class StateStoreTest {
    private StateStore store;

    @Before
    public void setUp() {
        store = new StateStore();
    }

    @Test
    public void initialStateIsStopped() {
        assertEquals(RecordService.State.STOPPED, store.get());
    }

    @Test
    public void publishNotifiesListenerWithNewState() {
        final RecordService.State[] seen = {null};
        store.setListener(state -> seen[0] = state);

        store.publish(RecordService.State.WAITING);

        assertEquals(RecordService.State.WAITING, seen[0]);
        assertEquals(RecordService.State.WAITING, store.get());
    }

    @Test
    public void lateListenerReceivesCurrentStateOnSubscribe() {
        store.publish(RecordService.State.STREAMING);

        final RecordService.State[] seen = {null};
        store.setListener(state -> seen[0] = state);

        assertEquals(RecordService.State.STREAMING, seen[0]);
    }

    @Test
    public void clearingListenerStopsNotifications() {
        final RecordService.State[] seen = {null};
        store.setListener(state -> seen[0] = state);
        store.setListener(null);
        seen[0] = null; // discard the replay-on-subscribe value

        store.publish(RecordService.State.ERROR);

        assertNull(seen[0]);
        assertEquals(RecordService.State.ERROR, store.get());
    }

    @Test
    public void errorPublishIsVisibleToListener() {
        final RecordService.State[] seen = {null};
        store.setListener(state -> seen[0] = state);

        store.publish(RecordService.State.ERROR);

        assertEquals(RecordService.State.ERROR, seen[0]);
    }
}
