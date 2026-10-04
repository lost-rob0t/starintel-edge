package actor.starintel.edge.service;

import java.io.File;
import java.util.Objects;
import java.util.concurrent.atomic.AtomicBoolean;

/** Platform lifecycle only. Lisp owns initialization, actors, policy and requests.
 * A backend must actually load the trusted init.lisp and prove local readiness.
 * Never substitute a remote proxy or treat successful class loading as readiness.
 */
public interface LocalRuntimeBackend {
    Session open(Config config, Cancellation cancellation) throws Exception;
    /** True once native boot was attempted; a later user start needs a fresh process. */
    default boolean requiresFreshProcess() { return false; }

    interface Session extends AutoCloseable {
        /** Bounded and idempotent; releases all owned listeners/threads. */
        @Override void close() throws Exception;
    }

    final class Config {
        public final File privateDirectory;
        public final File initFile;
        public final String listenAddress = "127.0.0.1";
        public final int listenPort = 5000;
        public Config(File privateDirectory, File initFile) {
            this.privateDirectory = Objects.requireNonNull(privateDirectory);
            this.initFile = Objects.requireNonNull(initFile);
        }
    }

    /** Cooperative cancellation. Implementations must bound every blocking step. */
    final class Cancellation {
        private final AtomicBoolean cancelled = new AtomicBoolean();
        public boolean isCancelled() { return cancelled.get(); }
        public void cancel() { cancelled.set(true); }
        public void check() throws InterruptedException {
            if (isCancelled()) throw new InterruptedException("Runtime start cancelled");
        }
    }

    final class Unavailable extends Exception {
        public Unavailable() { super("No verified Android Common Lisp backend is packaged"); }
    }

    /** Deliberately unavailable until a proven Android backend is installed at build time. */
    LocalRuntimeBackend UNAVAILABLE = (config, cancellation) -> { throw new Unavailable(); };
}
