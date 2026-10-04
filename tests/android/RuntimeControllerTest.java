package actor.starintel.edge.service;

import java.io.File;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.AbstractExecutorService;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;

/** Real host-JVM tests with fake effect ports. Never Android/Lisp execution evidence. */
public final class RuntimeControllerTest {
    private static int checks;
    private static void check(boolean value) { checks++; if (!value) throw new AssertionError("Check " + checks); }
    private static final LocalRuntimeBackend.Config CONFIG = new LocalRuntimeBackend.Config(
            new File("/synthetic/private"), new File("/synthetic/private/init.lisp"));
    private static final class ManualExecutor extends AbstractExecutorService {
        final ArrayDeque<Runnable> jobs = new ArrayDeque<>();
        boolean shutdown;
        @Override public void execute(Runnable command) { if (shutdown) throw new AssertionError("After shutdown"); jobs.add(command); }
        void run() { jobs.remove().run(); }
        @Override public void shutdown() { shutdown = true; }
        @Override public List<Runnable> shutdownNow() { shutdown = true; List<Runnable> old = new ArrayList<>(jobs); jobs.clear(); return old; }
        @Override public boolean isShutdown() { return shutdown; }
        @Override public boolean isTerminated() { return shutdown && jobs.isEmpty(); }
        @Override public boolean awaitTermination(long timeout, TimeUnit unit) { return isTerminated(); }
    }
    private static void lifecycle() throws Exception {
        ManualExecutor queue = new ManualExecutor();
        AtomicInteger opens = new AtomicInteger();
        AtomicInteger closes = new AtomicInteger();
        List<RuntimeController.Snapshot> states = new ArrayList<>();
        RuntimeController controller = new RuntimeController((config, cancel) -> {
            check(config == CONFIG); check(config.listenAddress.equals("127.0.0.1"));
            opens.incrementAndGet(); return () -> closes.incrementAndGet();
        }, states::add, queue);
        check(controller.snapshot().state == RuntimeController.State.STOPPED);
        check(controller.start(CONFIG));
        for (int i = 0; i < 100; i++) check(!controller.start(CONFIG));
        check(queue.jobs.size() == 1);
        check(controller.stop()); check(!controller.stop());
        queue.run();
        check(opens.get() == 0); check(controller.snapshot().state == RuntimeController.State.STOPPED);
        check(controller.start(CONFIG)); queue.run();
        check(controller.snapshot().state == RuntimeController.State.RUNNING);
        check(controller.stop()); check(controller.snapshot().state == RuntimeController.State.STOPPING);
        check(closes.get() == 0); queue.run(); check(closes.get() == 1);
        check(controller.snapshot().state == RuntimeController.State.STOPPED);
        check(controller.start(CONFIG)); queue.run(); controller.close();
        check(!controller.start(CONFIG)); queue.run(); check(closes.get() == 2);
        controller.close(); check(queue.isTerminated());
    }
    private static void failures() {
        ManualExecutor queue = new ManualExecutor();
        RuntimeController controller = new RuntimeController(LocalRuntimeBackend.UNAVAILABLE, s -> {}, queue);
        controller.start(CONFIG); queue.run();
        check(controller.snapshot().state == RuntimeController.State.UNAVAILABLE);
        check(controller.snapshot().reason == RuntimeController.Reason.BACKEND_MISSING);
        check(!controller.snapshot().active()); controller.close();
        for (LocalRuntimeBackend backend : new LocalRuntimeBackend[]{
                (c, x) -> { throw new Exception("synthetic-secret-must-not-be-status"); }, (c, x) -> null,
                (c, x) -> { throw new NoClassDefFoundError("missing Lisp runtime"); }}) {
            queue = new ManualExecutor();
            controller = new RuntimeController(backend, s -> {}, queue);
            controller.start(CONFIG); queue.run();
            check(controller.snapshot().state == RuntimeController.State.FAILED);
            check(controller.snapshot().reason == RuntimeController.Reason.START_FAILED);
            controller.close();
        }
        AtomicInteger closeAttempts = new AtomicInteger();
        queue = new ManualExecutor();
        controller = new RuntimeController((c, x) -> () -> {
            if (closeAttempts.incrementAndGet() == 1) throw new Exception("cleanup failed");
        }, s -> {}, queue);
        controller.start(CONFIG); queue.run(); controller.stop(); queue.run();
        check(controller.snapshot().active());
        check(controller.snapshot().reason == RuntimeController.Reason.STOP_FAILED);
        check(!controller.start(CONFIG)); // Do not create another runtime over leaked resources.
        check(controller.stop()); queue.run();
        check(closeAttempts.get() == 2); check(!controller.snapshot().active()); controller.close();
    }
    private static void cancelledInFlight() throws Exception {
        CountDownLatch entered = new CountDownLatch(1), release = new CountDownLatch(1), stopped = new CountDownLatch(1);
        AtomicInteger closes = new AtomicInteger();
        RuntimeController controller = new RuntimeController((config, cancellation) -> {
            entered.countDown();
            if (!release.await(2, TimeUnit.SECONDS)) throw new AssertionError("Test blocked");
            return () -> closes.incrementAndGet();
        }, s -> { if (s.state == RuntimeController.State.STOPPED) stopped.countDown(); });
        controller.start(CONFIG); check(entered.await(2, TimeUnit.SECONDS));
        controller.stop(); release.countDown(); check(stopped.await(2, TimeUnit.SECONDS));
        check(closes.get() == 1); check(controller.snapshot().state == RuntimeController.State.STOPPED);
        controller.close();
    }
    private static void stableNativeThread() throws Exception {
        java.util.Set<Long> threads = java.util.Collections.synchronizedSet(new java.util.HashSet<>());
        java.util.concurrent.BlockingQueue<RuntimeController.State> states = new java.util.concurrent.LinkedBlockingQueue<>();
        RuntimeController controller = new RuntimeController((config, cancellation) -> {
            threads.add(Thread.currentThread().getId());
            return () -> threads.add(Thread.currentThread().getId());
        }, snapshot -> states.offer(snapshot.state));
        for (int pass = 0; pass < 3; pass++) {
            check(controller.start(CONFIG));
            check(states.poll(2, TimeUnit.SECONDS) == RuntimeController.State.STARTING);
            check(states.poll(2, TimeUnit.SECONDS) == RuntimeController.State.RUNNING);
            check(controller.stop());
            check(states.poll(2, TimeUnit.SECONDS) == RuntimeController.State.STOPPING);
            check(states.poll(2, TimeUnit.SECONDS) == RuntimeController.State.STOPPED);
        }
        check(threads.size() == 1);
        check(!threads.contains(Thread.currentThread().getId()));
        controller.close();
    }
    private static void initFile() throws Exception {
        Path root = Files.createTempDirectory("edge-init-synthetic-");
        try {
            byte[] template = "(in-package :cl-user)\n".getBytes(StandardCharsets.UTF_8);
            File init = PrivateInitFile.ensure(root.toFile(), template);
            check(java.util.Arrays.equals(template, Files.readAllBytes(init.toPath())));
            byte[] custom = ";; trusted operator Lisp remains Lisp\n(+ 1 2)\n".getBytes(StandardCharsets.UTF_8);
            Files.write(init.toPath(), custom);
            check(PrivateInitFile.ensure(root.toFile(), template).equals(init));
            check(java.util.Arrays.equals(custom, Files.readAllBytes(init.toPath())));
            Files.delete(init.toPath());
            Files.createSymbolicLink(root.resolve("init.lisp"), root.resolve("other.lisp"));
            boolean rejected = false;
            try { PrivateInitFile.ensure(root.toFile(), template); } catch (java.io.IOException expected) { rejected = true; }
            check(rejected);
            Files.delete(root.resolve("init.lisp"));
            Files.write(root.resolve("init.lisp"), new byte[1024 * 1024 + 1]);
            rejected = false;
            try { PrivateInitFile.ensure(root.toFile(), template); } catch (java.io.IOException expected) { rejected = true; }
            check(rejected);
        } finally {
            try (var files = Files.list(root)) { for (Path file : files.toList()) Files.delete(file); }
            Files.delete(root);
        }
    }
    public static void main(String[] args) throws Exception {
        lifecycle(); failures(); cancelledInFlight(); stableNativeThread(); initFile();
        System.out.println(checks + " host-JVM lifecycle/init checks passed (fake backends; not ART/APK/Lisp evidence).");
    }
}
