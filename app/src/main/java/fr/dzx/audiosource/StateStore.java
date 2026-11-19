package fr.dzx.audiosource;

/**
 * Pure-Java holder for the recording service's UI state and its listener
 * fan-out. Extracted from RecordService so state semantics (initial value,
 * publish, replay-on-subscribe) are unit-testable without an Android
 * runtime. Thread-safety mirrors the original volatile fields: one volatile
 * state, one volatile listener, no locks.
 */
final class StateStore {
    private volatile RecordService.State state = RecordService.State.STOPPED;
    private volatile RecordService.StateListener listener;

    RecordService.State get() {
        return state;
    }

    /** Subscribe; a non-null listener immediately receives the current state. */
    void setListener(RecordService.StateListener next) {
        listener = next;
        if (next != null) next.onStateChanged(state);
    }

    void publish(RecordService.State next) {
        state = next;
        RecordService.StateListener current = listener;
        if (current != null) current.onStateChanged(next);
    }
}
