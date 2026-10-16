package actor.starintel.edge.service;

import java.io.File;
import java.nio.file.Files;

/** Host C-stub integration of the production lifecycle/pipe port; never Lisp evidence. */
public final class OwnedLifecycleTest {
    private static int assertions;
    private static void check(boolean value) {
        assertions++;
        if (!value) throw new AssertionError();
    }
    public static void main(String[] args) throws Exception {
        File libraries = new File(args[0]), directory = new File(args[1]);
        File init = new File(directory, "init.lisp");
        Files.writeString(init.toPath(), "synthetic init preserved");
        LocalRuntimeBackend.Config config = new LocalRuntimeBackend.Config(directory, init);
        for (boolean accept : new boolean[]{true, false}) {
            int[] calls = {0, 0};
            OwnedEclNativePort port = new OwnedEclNativePort(libraries, new OwnedEclNativePort.Responses() {
                public boolean ready(String ping, String state, String actor) {
                    calls[0]++;
                    // The stub ECHOES each request; these are NOT ready responses.
                    check(ping.equals("{\"op\":\"runtime.ping\"}"));
                    check(state.equals("{\"op\":\"service.status\"}"));
                    check(actor.equals("{\"op\":\"actor.roundtrip\"}"));
                    return accept;
                }
                public boolean stopped(String text) {
                    calls[1]++;
                    check(text.equals("{\"op\":\"service.stop\"}"));
                    return true;
                }
            });
            EclLifecycle lifecycle = new EclLifecycle(port, (path, cancel) -> cancel.check());
            if (accept) {
                LocalRuntimeBackend.Session session = lifecycle.open(config, new LocalRuntimeBackend.Cancellation());
                session.close(); session.close();
            } else {
                try { lifecycle.open(config, new LocalRuntimeBackend.Cancellation()); throw new AssertionError(); }
                catch (IllegalStateException expected) { check(expected.getMessage().contains("not ready")); }
            }
            check(calls[0] == 1 && calls[1] == 1);
            check(lifecycle.requiresFreshProcess());
            check(Files.readString(init.toPath()).equals("synthetic init preserved"));
            try { lifecycle.open(config, new LocalRuntimeBackend.Cancellation()); throw new AssertionError(); }
            catch (IllegalStateException expected) { check(expected.getMessage().contains("Fresh")); }
        }
        try {
            new OwnedEclNativePort(new File(directory, "missing"), null).abiVersion();
            throw new AssertionError();
        } catch (LocalRuntimeBackend.Unavailable expected) { check(true); }
        System.out.println("PASS " + assertions + " host C-stub owned lifecycle assertions; NO ECL/ART proof");
    }
}
