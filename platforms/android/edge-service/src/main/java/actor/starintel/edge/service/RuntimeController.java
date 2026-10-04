package actor.starintel.edge.service;

import java.util.Objects;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.function.Consumer;

/** Serializes platform resource ownership, not Lisp runtime/actor semantics.
 * Admission bounds work to one start or stop; repeated UI commands cannot queue work.
 * Observer receives only redacted enum values, never backend exception messages.
 */
public final class RuntimeController implements AutoCloseable {
    public enum State { STOPPED, STARTING, RUNNING, STOPPING, UNAVAILABLE, FAILED }
    public enum Reason { NONE, USER_STOP, BACKEND_MISSING, START_FAILED, STOP_FAILED, PROCESS_RESTART_REQUIRED }
    public static final class Snapshot {
        public final State state;
        public final Reason reason;
        private Snapshot(State state, Reason reason) { this.state = state; this.reason = reason; }
        public boolean active() { return state == State.STARTING || state == State.RUNNING || state == State.STOPPING || (state == State.FAILED && reason == Reason.STOP_FAILED); }
    }

    private final LocalRuntimeBackend backend;
    private final ExecutorService worker;
    private final Consumer<Snapshot> observer;
    private volatile Snapshot snapshot = new Snapshot(State.STOPPED, Reason.NONE);
    private LocalRuntimeBackend.Cancellation cancellation;
    private LocalRuntimeBackend.Session session;
    private boolean closed;

    public RuntimeController(LocalRuntimeBackend backend, Consumer<Snapshot> observer) {
        this(backend, observer, Executors.newSingleThreadExecutor(r -> new Thread(r, "star-edge-runtime")));
    }
    public RuntimeController(LocalRuntimeBackend backend, Consumer<Snapshot> observer, ExecutorService worker) {
        this.backend = Objects.requireNonNull(backend);
        this.observer = Objects.requireNonNull(observer);
        this.worker = Objects.requireNonNull(worker);
    }
    public Snapshot snapshot() { return snapshot; }
    public boolean requiresFreshProcess() { return backend.requiresFreshProcess(); }
    private void transition(State state, Reason reason) {
        snapshot = new Snapshot(state, reason);
        // The observer must be nonblocking; Android's observer posts to its main handler.
        observer.accept(snapshot);
    }
    public synchronized boolean start(LocalRuntimeBackend.Config config) {
        Objects.requireNonNull(config);
        if (closed || snapshot.active()) return false;
        if (backend.requiresFreshProcess()) {
            transition(State.UNAVAILABLE, Reason.PROCESS_RESTART_REQUIRED);
            return false;
        }
        cancellation = new LocalRuntimeBackend.Cancellation();
        LocalRuntimeBackend.Cancellation current = cancellation;
        transition(State.STARTING, Reason.NONE);
        worker.execute(() -> open(config, current));
        return true;
    }
    private void open(LocalRuntimeBackend.Config config, LocalRuntimeBackend.Cancellation current) {
        LocalRuntimeBackend.Session opened = null;
        Reason failure = Reason.NONE;
        try {
            current.check();
            opened = Objects.requireNonNull(backend.open(config, current), "Backend returned no session");
        } catch (LocalRuntimeBackend.Unavailable e) {
            failure = Reason.BACKEND_MISSING;
        } catch (Exception | LinkageError e) {
            failure = Reason.START_FAILED;
        }
        synchronized (this) {
            if (!current.isCancelled() && failure == Reason.NONE) {
                session = opened;
                transition(State.RUNNING, Reason.NONE);
                return;
            }
        }
        boolean clean = dispose(opened);
        synchronized (this) {
            if (!clean) { session = opened; transition(State.FAILED, Reason.STOP_FAILED); }
            else if (current.isCancelled()) transition(State.STOPPED, Reason.USER_STOP);
            else transition(failure == Reason.BACKEND_MISSING ? State.UNAVAILABLE : State.FAILED, failure);
        }
    }
    public synchronized boolean stop() {
        if (!snapshot.active() || snapshot.state == State.STOPPING) return false;
        cancellation.cancel();
        State previous = snapshot.state;
        transition(State.STOPPING, Reason.USER_STOP);
        if (previous == State.RUNNING || previous == State.FAILED) {
            LocalRuntimeBackend.Session owned = session;
            worker.execute(() -> {
                boolean clean = dispose(owned);
                synchronized (RuntimeController.this) {
                    if (clean) session = null;
                    transition(clean ? State.STOPPED : State.FAILED,
                            clean ? Reason.USER_STOP : Reason.STOP_FAILED);
                }
            });
        }
        // STARTING owns its eventual result and disposes it before reporting STOPPED.
        return true;
    }
    private boolean dispose(LocalRuntimeBackend.Session owned) {
        if (owned == null) return true;
        try { owned.close(); return true; }
        catch (Exception | LinkageError e) { return false; }
    }
    @Override public synchronized void close() {
        if (closed) return;
        closed = true;
        stop();
        // Does not block Android's main thread; admitted cleanup is allowed to finish.
        worker.shutdown();
    }
}
