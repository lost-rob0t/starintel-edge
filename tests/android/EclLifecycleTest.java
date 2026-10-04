package actor.starintel.edge.service;

import java.io.ByteArrayInputStream;
import java.io.File;
import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

/** Real orchestration/asset code with synthetic native ports; never native/ART proof. */
public final class EclLifecycleTest {
    private static int checks;
    static void check(boolean value) { checks++; if (!value) throw new AssertionError("Check " + checks); }
    private static class Native implements EclLifecycle.NativePort {
        int abi = 1; boolean ready = true; String startError;
        List<String> events = new ArrayList<>(); Runnable onStart = () -> {};
        @Override public int abiVersion() { events.add("abi"); return abi; }
        @Override public String start(String directory) { events.add("start"); onStart.run(); return startError; }
        @Override public boolean localServiceReady() { events.add("ready"); return ready; }
        @Override public boolean stopManagedRuntime() { events.add("lisp-stop"); return true; }
        @Override public void stop() { events.add("native-stop"); }
    }
    private static void lifecycle(Path root) throws Exception {
        LocalRuntimeBackend.Config config = new LocalRuntimeBackend.Config(root.toFile(), root.resolve("init.lisp").toFile());
        Native nativePort = new Native();
        EclLifecycle backend = new EclLifecycle(nativePort, (directory, cancellation) -> nativePort.events.add("assets"));
        LocalRuntimeBackend.Session session = backend.open(config, new LocalRuntimeBackend.Cancellation());
        check(nativePort.events.equals(List.of("abi", "assets", "start", "ready")));
        session.close(); session.close();
        check(backend.requiresFreshProcess());
        boolean repeated = false;
        try { backend.open(config, new LocalRuntimeBackend.Cancellation()); }
        catch (IllegalStateException expected) { repeated = true; }
        check(repeated);
        check(nativePort.events.equals(List.of("abi", "assets", "start", "ready", "lisp-stop", "native-stop")));
        for (boolean wrongAbi : new boolean[]{true, false}) {
            Native bad = new Native();
            if (wrongAbi) bad.abi = 2; else bad.ready = false;
            backend = new EclLifecycle(bad, (directory, cancellation) -> {});
            boolean rejected = false;
            try { backend.open(config, new LocalRuntimeBackend.Cancellation()); } catch (IllegalStateException expected) { rejected = true; }
            check(rejected);
            check(wrongAbi ? bad.events.equals(List.of("abi")) : bad.events.equals(List.of("abi", "start", "ready", "lisp-stop", "native-stop")));
        }
        Native failing = new Native(); failing.startError = "stable-start-error";
        backend = new EclLifecycle(failing, (directory, cancellation) -> {});
        boolean rejected = false;
        try { backend.open(config, new LocalRuntimeBackend.Cancellation()); } catch (IllegalStateException expected) { rejected = true; }
        check(rejected); check(failing.events.equals(List.of("abi", "start", "lisp-stop", "native-stop")));
        Native cancelled = new Native(); LocalRuntimeBackend.Cancellation token = new LocalRuntimeBackend.Cancellation();
        cancelled.onStart = token::cancel;
        backend = new EclLifecycle(cancelled, (directory, cancellation) -> {});
        rejected = false;
        try { backend.open(config, token); } catch (InterruptedException expected) { rejected = true; }
        check(rejected); check(cancelled.events.equals(List.of("abi", "start", "lisp-stop", "native-stop")));
        Native missing = new Native() { @Override public int abiVersion() { throw new UnsatisfiedLinkError(); } };
        backend = new EclLifecycle(missing, (directory, cancellation) -> { throw new AssertionError("No assets without native ABI"); });
        rejected = false;
        try { backend.open(config, new LocalRuntimeBackend.Cancellation()); } catch (LocalRuntimeBackend.Unavailable expected) { rejected = true; }
        check(rejected);
    }
    private static class InlineExecutor extends java.util.concurrent.AbstractExecutorService {
        private boolean stopped;
        @Override public void execute(Runnable job) { if (stopped) throw new IllegalStateException(); job.run(); }
        @Override public void shutdown() { stopped = true; }
        @Override public java.util.List<Runnable> shutdownNow() { stopped = true; return java.util.List.of(); }
        @Override public boolean isShutdown() { return stopped; }
        @Override public boolean isTerminated() { return stopped; }
        @Override public boolean awaitTermination(long timeout, java.util.concurrent.TimeUnit unit) { return stopped; }
    }
    private static void failedCleanup(Path root) throws Exception {
        LocalRuntimeBackend.Config config = new LocalRuntimeBackend.Config(root.toFile(), root.resolve("init.lisp").toFile());
        for (int scenario = 0; scenario < 3; scenario++) {
            final int failure = scenario;
            Native port = new Native() {
                @Override public boolean stopManagedRuntime() {
                    events.add("lisp-stop");
                    if (failure == 1) throw new IllegalStateException("synthetic managed failure");
                    return failure != 0;
                }
                @Override public void stop() {
                    events.add("native-stop");
                    if (failure == 2) throw new IllegalStateException("synthetic native failure");
                }
            };
            EclLifecycle backend = new EclLifecycle(port, (directory, cancellation) -> {});
            RuntimeController owner = new RuntimeController(backend, state -> {}, new InlineExecutor());
            check(owner.start(config));
            check(owner.snapshot().state == RuntimeController.State.RUNNING);
            check(owner.stop());
            check(owner.snapshot().state == RuntimeController.State.FAILED);
            check(owner.snapshot().reason == RuntimeController.Reason.STOP_FAILED);
            check(owner.snapshot().active());
            check(owner.requiresFreshProcess());
            check(!owner.start(config));
            check(port.events.equals(List.of("abi", "start", "ready", "lisp-stop", "native-stop")));
            owner.close();
            check(!owner.start(config));
        }
    }
    private static class Source implements RuntimeAssets.Source {
        final Map<String, String> files = new HashMap<>();
        boolean fail;
        Source() { files.put("starintel-edge/lisp/startup.lisp", ";; synthetic Lisp\n"); files.put("starintel-edge/ecl/data", "synthetic runtime source"); }
        @Override public String[] list(String path) {
            return files.keySet().stream().filter(key -> key.startsWith(path + "/"))
                    .map(key -> key.substring(path.length() + 1).split("/", 2)[0]).distinct().sorted().toArray(String[]::new);
        }
        @Override public InputStream open(String path) throws IOException {
            if (fail || !files.containsKey(path)) throw new IOException("Synthetic interrupted asset copy");
            return new ByteArrayInputStream(files.get(path).getBytes(StandardCharsets.UTF_8));
        }
    }
    private static void assets(Path root) throws Exception {
        Files.writeString(root.resolve("init.lisp"), "(+ 2 2)");
        Files.createDirectories(root.resolve("state")); Files.writeString(root.resolve("state/journal"), "pending synthetic item");
        Files.createDirectories(root.resolve("lisp")); Files.writeString(root.resolve("lisp/stale.asd"), "must never load");
        Source source = new Source(); RuntimeAssets assets = new RuntimeAssets(source);
        assets.install(root.toFile(), new LocalRuntimeBackend.Cancellation());
        check(Files.readString(root.resolve("init.lisp")).equals("(+ 2 2)"));
        check(Files.readString(root.resolve("state/journal")).equals("pending synthetic item"));
        check(!Files.exists(root.resolve("lisp/stale.asd")));
        check(Files.readString(root.resolve("lisp/startup.lisp")).equals(";; synthetic Lisp\n"));
        source.fail = true;
        boolean rejected = false;
        try { assets.install(root.toFile(), new LocalRuntimeBackend.Cancellation()); } catch (IOException expected) { rejected = true; }
        check(rejected); check(Files.readString(root.resolve("init.lisp")).equals("(+ 2 2)"));
        source.fail = false; assets.install(root.toFile(), new LocalRuntimeBackend.Cancellation());
        check(Files.exists(root.resolve("lisp/startup.lisp")));
        LocalRuntimeBackend.Cancellation cancelled = new LocalRuntimeBackend.Cancellation(); cancelled.cancel();
        rejected = false;
        try { assets.install(root.toFile(), cancelled); } catch (InterruptedException expected) { rejected = true; }
        check(rejected);
        source.files.put("starintel-edge/lisp/../outside", "not allowed");
        rejected = false;
        try { assets.install(root.toFile(), new LocalRuntimeBackend.Cancellation()); } catch (IOException expected) { rejected = true; }
        check(rejected); check(!Files.exists(root.resolve("outside")));
    }
    private static void assetBounds(Path root) throws Exception {
        Source large = new Source() {
            @Override public InputStream open(String path) throws IOException {
                if (path.equals("starintel-edge/ecl/data")) return new InputStream() {
                    private int remaining = 33 * 1024 * 1024;
                    @Override public int read() { return remaining-- > 0 ? 0 : -1; }
                    @Override public int read(byte[] buffer, int offset, int length) {
                        if (remaining <= 0) return -1;
                        int n = Math.min(remaining, length); remaining -= n; return n;
                    }
                };
                return super.open(path);
            }
        };
        boolean rejected = false;
        try { new RuntimeAssets(large).install(root.toFile(), new LocalRuntimeBackend.Cancellation()); }
        catch (IOException expected) { rejected = true; }
        check(rejected); check(!Files.exists(root.resolve("ecl/data")));
        check(Files.readString(root.resolve("init.lisp")).equals("(+ 2 2)"));
        Path link = root.resolve("root-link"); Files.createSymbolicLink(link, root);
        rejected = false;
        try { new RuntimeAssets(new Source()).install(link.toFile(), new LocalRuntimeBackend.Cancellation()); }
        catch (IOException expected) { rejected = true; }
        check(rejected); Files.delete(link);
    }
    public static void main(String[] args) throws Exception {
        Path root = Files.createTempDirectory("edge-ecl-synthetic-");
        try { lifecycle(root); failedCleanup(root); assets(root); assetBounds(root); }
        finally { try (var paths = Files.walk(root)) { for (Path p : paths.sorted(java.util.Comparator.reverseOrder()).toList()) Files.delete(p); } }
        System.out.println(checks + " ECL orchestration/asset tests passed with fake native ports; not native/ART evidence.");
    }
}
