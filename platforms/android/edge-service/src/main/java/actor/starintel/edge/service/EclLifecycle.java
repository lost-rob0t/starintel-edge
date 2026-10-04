package actor.starintel.edge.service;

import java.io.File;

/** Lifecycle orchestration over the existing upstream native ABI. No Lisp boot/actor implementation. */
public final class EclLifecycle implements LocalRuntimeBackend {
    public interface NativePort {
        int abiVersion();
        String start(String runtimeDirectory);
        boolean localServiceReady();
        boolean stopManagedRuntime();
        void stop();
    }
    public interface Assets { void install(File destination, Cancellation cancellation) throws Exception; }
    private final NativePort nativePort;
    private final Assets assets;
    private volatile boolean bootAttempted;
    public EclLifecycle(NativePort nativePort, Assets assets) { this.nativePort = nativePort; this.assets = assets; }
    @Override public boolean requiresFreshProcess() { return bootAttempted; }
    @Override public Session open(Config config, Cancellation cancellation) throws Exception {
        if (bootAttempted) throw new IllegalStateException("Fresh runtime process required");
        try {
            if (nativePort.abiVersion() != 1) throw new IllegalStateException("Native ABI mismatch");
        } catch (UnsatisfiedLinkError | NoClassDefFoundError missing) { throw new Unavailable(); }
        cancellation.check();
        assets.install(config.privateDirectory, cancellation);
        cancellation.check();
        boolean attempted = false;
        try {
            attempted = true;
            bootAttempted = true;
            if (nativePort.start(config.privateDirectory.getAbsolutePath()) != null)
                throw new IllegalStateException("Native startup failed");
            cancellation.check();
            // Ping alone only proves dispatch. This port also checks the trusted-init actor profile.
            if (!nativePort.localServiceReady()) throw new IllegalStateException("Local actor runtime not ready");
            cancellation.check();
            return new Session() {
                private boolean stopped;
                @Override public void close() {
                    if (stopped) return;
                    boolean graceful;
                    try { graceful = nativePort.stopManagedRuntime(); }
                    finally { nativePort.stop(); stopped = true; }
                    if (!graceful) throw new IllegalStateException("Managed runtime teardown was not confirmed");
                }
            };
        } catch (Exception | LinkageError failure) {
            if (attempted) {
                try { nativePort.stopManagedRuntime(); }
                finally { nativePort.stop(); }
            }
            throw failure;
        }
    }
}
