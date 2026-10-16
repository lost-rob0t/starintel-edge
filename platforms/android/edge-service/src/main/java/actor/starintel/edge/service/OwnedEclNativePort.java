package actor.starintel.edge.service;

import java.io.File;
import java.io.IOException;

/** Lifecycle port for one standalone ECL child. Never loads native libraries into ART. */
public final class OwnedEclNativePort implements EclLifecycle.NativePort {
    public interface Responses {
        boolean ready(String ping, String status, String actor) throws Exception;
        boolean stopped(String response) throws Exception;
    }
    // Packaged ECL/Sento measured 22.2 seconds on API 36 x86_64. Include
    // bounded cold-load margin; RuntimeOwner also bounds the whole startup.
    static final long STARTUP_TIMEOUT_MILLIS = 60000;
    private final File libraries;
    private final Responses responses;
    private volatile OwnedEclProcess process;
    private boolean attempted;
    public OwnedEclNativePort(File libraries, Responses responses) {
        this.libraries = libraries;
        this.responses = responses;
    }
    @Override public boolean isAlive() { return process != null && process.isAlive(); }
    @Override public int abiVersion() throws LocalRuntimeBackend.Unavailable {
        if (!new File(libraries, "libstarintel_ecl_runner.so").canExecute())
            throw new LocalRuntimeBackend.Unavailable();
        // Protocol version, not native readiness. start validates the child's actual ABI handshake.
        return 1;
    }
    @Override public String start(String directory) throws Exception {
        if (attempted) throw new IllegalStateException("Fresh runtime owner required");
        attempted = true;
        process = OwnedEclProcess.start(libraries, new File(directory), STARTUP_TIMEOUT_MILLIS);
        return null;
    }
    @Override public boolean localServiceReady() throws Exception {
        return process != null && responses.ready(
                process.request("{\"op\":\"runtime.ping\"}", 2000),
                process.request("{\"op\":\"service.status\"}", 2000),
                process.request("{\"op\":\"actor.roundtrip\"}", 2000));
    }
    @Override public boolean stopManagedRuntime() throws Exception {
        return process == null || responses.stopped(process.request("{\"op\":\"service.stop\"}", 2000));
    }
    @Override public void stop() throws Exception {
        if (process == null) return;
        try { process.close(3000); }
        catch (Exception failed) {
            // Exit observation is independent from graceful shutdown. Never turn failure into success.
            if (!process.awaitRetirement(1000))
                throw new IOException("Owned ECL retirement unconfirmed", failed);
            throw failed;
        }
    }
}
