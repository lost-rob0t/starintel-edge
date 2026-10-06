package actor.starintel.edge.service;

import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.DataOutputStream;
import java.io.File;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.Arrays;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicReference;

/** Host JVM + C ABI TEST DOUBLE only. Not Android/ART/ECL acceptance. */
public final class OwnedProcessTest {
    private static File libraries, runtime;
    private static int checks;
    private static final String HELLO = "{\"transport\":\"starintel-owned/1\",\"abi\":1}";
    @FunctionalInterface interface Check { void run() throws Exception; }
    private static void ok(boolean pass, String label) { if (!pass) throw new AssertionError(label); checks++; }
    private static void fails(Class<? extends Throwable> type, Check action, String label) throws Exception {
        try { action.run(); } catch (Throwable error) {
            if (type.isInstance(error)) { checks++; return; }
            throw new AssertionError(label, error);
        }
        throw new AssertionError("Expected failure: " + label);
    }
    private static Process launch(String... environment) throws IOException {
        ProcessBuilder builder = new ProcessBuilder(new File(libraries, "libstarintel_ecl_runner.so").getPath(), runtime.getPath());
        builder.environment().put("LD_LIBRARY_PATH", libraries.getPath());
        for (int i = 0; i < environment.length; i += 2) builder.environment().put(environment[i], environment[i + 1]);
        return builder.start();
    }
    private static void untilDead(Process process, String label) throws Exception {
        ok(process != null && process.waitFor(4000, TimeUnit.MILLISECONDS), label);
    }
    private static byte[] frame(byte[] bytes) throws IOException {
        ByteArrayOutputStream data = new ByteArrayOutputStream();
        DataOutputStream out = new DataOutputStream(data); out.writeInt(bytes.length); out.write(bytes);
        return data.toByteArray();
    }
    private static byte[] join(byte[]... parts) throws IOException {
        ByteArrayOutputStream out = new ByteArrayOutputStream(); for (byte[] p : parts) out.write(p); return out.toByteArray();
    }
    private static byte[] utf(String value) { return value.getBytes(StandardCharsets.UTF_8); }
    private static class FakeProcess extends Process {
        final InputStream input;
        final ByteArrayOutputStream output = new ByteArrayOutputStream();
        boolean alive = true;
        FakeProcess(byte[] bytes) { input = new ByteArrayInputStream(bytes); }
        @Override public OutputStream getOutputStream() { return output; }
        @Override public InputStream getInputStream() { return input; }
        @Override public InputStream getErrorStream() { return new ByteArrayInputStream(new byte[0]); }
        @Override public synchronized int waitFor() throws InterruptedException { while (alive) wait(); return 0; }
        @Override public synchronized int exitValue() { if (alive) throw new IllegalThreadStateException(); return 0; }
        @Override public synchronized void destroy() { alive = false; notifyAll(); }
    }
    private static void malformedResponses() throws Exception {
        byte[][] responses = {
            {0, 0, 0, 0}, {0, 64, 0, 1}, {(byte)255, (byte)255, (byte)255, (byte)255},
            {0, 0}, {0, 0, 0, 2, 'x'}, frame(new byte[]{(byte)0xc0, (byte)0x80}),
            frame(new byte[]{'x', 0, 'y'}), frame(new byte[]{(byte)0xed, (byte)0xa0, (byte)0x80})
        };
        for (byte[] response : responses) {
            FakeProcess process = new FakeProcess(join(frame(utf(HELLO)), response));
            OwnedEclProcess client = new OwnedEclProcess(() -> process, 1000);
            fails(IOException.class, () -> client.request("{}", 1000), "malformed response");
            ok(client.awaitRetirement(1000), "malformed response owned cleanup");
        }
        FakeProcess badHello = new FakeProcess(frame(utf("wrong-abi")));
        fails(IOException.class, () -> new OwnedEclProcess(() -> badHello, 1000), "bad handshake");
        untilDead(badHello, "bad handshake cleanup");
    }
    private static void unicodeAndBounds() throws Exception {
        OwnedEclProcess client = OwnedEclProcess.start(libraries, runtime, 3000);
        for (String value : Arrays.asList("{}", "é漢字😀", "{\"payload\":\"\\u0000\"}", "x".repeat(1024 * 1024)))
            ok(client.request(value, 3000).equals(value), "exact UTF-8/stub echo");
        for (String value : Arrays.asList("", "x\0tail", "\ud800", "\udc00", "\ud800x", "x".repeat(1024 * 1024 + 1), "é".repeat(1024 * 1024)))
            fails(IOException.class, () -> client.request(value, 3000), "invalid request before dispatch");
        ok(client.request("large", 3000).length() == 4 * 1024 * 1024, "maximum response accepted");
        client.close(3000);
        client.close(3000); checks++; // Closeable successful-close idempotence.
        ok(client.awaitRetirement(1000), "graceful ack plus actual exit");
        fails(IllegalStateException.class, () -> client.request("{}", 1000), "no implicit restart");
    }
    private static void deadlinesAndAdmission() throws Exception {
        AtomicReference<Process> child = new AtomicReference<>();
        File marker = new File(runtime, "admission-test.log");
        Files.writeString(marker.toPath(), "");
        OwnedEclProcess client = new OwnedEclProcess(() -> { Process p = launch("STUB_LOG", marker.getPath()); child.set(p); return p; }, 3000);
        CountDownLatch entered = new CountDownLatch(1);
        AtomicReference<Throwable> failure = new AtomicReference<>();
        Thread request = new Thread(() -> {
            entered.countDown();
            try { client.request("hang", 800); } catch (Throwable expected) { failure.set(expected); }
        });
        long before = System.nanoTime(); request.start(); entered.await();
        // Wait for the admission itself, using request entry backed by the stub marker.
        long admittedBy = System.nanoTime() + TimeUnit.SECONDS.toNanos(2);
        while (!Files.readString(marker.toPath()).contains("request-hanging") && System.nanoTime() < admittedBy) Thread.sleep(5);
        ok(Files.readString(marker.toPath()).contains("request-hanging"), "request actually admitted");
        fails(IllegalStateException.class, () -> client.request("{}", 1000), "parallel request rejected");
        fails(IllegalStateException.class, () -> client.close(1000), "parallel close rejected");
        request.join(3000); ok(!request.isAlive() && failure.get() instanceof IOException, "request deadline");
        ok(TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - before) < 2500, "caller deadline bounded");
        ok(client.awaitRetirement(3000), "deadline cleanup confirmed on host"); untilDead(child.get(), "owned host child gone");
        // Existing unrelated child is never targeted.
        Process unrelated = launch();
        try {
            AtomicReference<Process> late = new AtomicReference<>();
            fails(IOException.class, () -> new OwnedEclProcess(() -> {
                try { Thread.sleep(250); } catch (InterruptedException e) { throw new IOException(e); }
                Process p = launch(); late.set(p); return p;
            }, 40), "constructor deadline before publication");
            long end = System.nanoTime() + TimeUnit.SECONDS.toNanos(4);
            while (late.get() == null && System.nanoTime() < end) Thread.sleep(10);
            untilDead(late.get(), "late-created child retired");
            ok(unrelated.isAlive(), "unrelated child preserved");
        } finally { unrelated.destroy(); unrelated.waitFor(); }
        AtomicReference<Process> interruptedChild = new AtomicReference<>();
        CountDownLatch launching = new CountDownLatch(1), release = new CountDownLatch(1);
        AtomicReference<Throwable> interrupted = new AtomicReference<>();
        Thread caller = new Thread(() -> {
            try {
                new OwnedEclProcess(() -> {
                    launching.countDown();
                    try { release.await(); } catch (InterruptedException e) { throw new IOException(e); }
                    Process p = launch(); interruptedChild.set(p); return p;
                }, 3000);
            } catch (Throwable expected) { interrupted.set(expected); }
        });
        caller.start(); launching.await(); caller.interrupt(); caller.join(1000); release.countDown();
        ok(interrupted.get() instanceof InterruptedException, "constructor interruption");
        long end = System.nanoTime() + TimeUnit.SECONDS.toNanos(4);
        while (interruptedChild.get() == null && System.nanoTime() < end) Thread.sleep(10);
        untilDead(interruptedChild.get(), "interrupted late launch retired");
    }
    private static void retainedCreatorAndShutdown() throws Exception {
        AtomicReference<OwnedEclProcess> value = new AtomicReference<>();
        AtomicReference<Throwable> error = new AtomicReference<>();
        Thread transientCaller = new Thread(() -> {
            try { value.set(OwnedEclProcess.start(libraries, runtime, 3000)); }
            catch (Throwable failure) { error.set(failure); }
        });
        transientCaller.start(); transientCaller.join(4000);
        ok(!transientCaller.isAlive() && error.get() == null, "application creator thread exited");
        Thread.sleep(100);
        ok(value.get().request("still-owned", 1000).equals("still-owned"), "retained worker prevents premature PDEATHSIG");
        value.get().close(3000);
        OwnedEclProcess noisy = new OwnedEclProcess(() -> launch("STUB_STDERR", "1"), 3000);
        ok(noisy.request("{}", 1000).equals("{}"), "stderr drained without contaminating frames"); noisy.close(3000);
        for (String mode : Arrays.asList("STUB_START_MS", "STUB_EXIT_MS")) {
            AtomicReference<Process> p = new AtomicReference<>();
            if (mode.equals("STUB_START_MS")) {
                fails(IOException.class, () -> new OwnedEclProcess(() -> { Process q = launch(mode, "5000"); p.set(q); return q; }, 100), "boot handshake deadline");
            } else {
                OwnedEclProcess client = new OwnedEclProcess(() -> { Process q = launch(mode, "5000"); p.set(q); return q; }, 3000);
                fails(IOException.class, () -> client.close(100), "ack without actual exit is not graceful success");
                ok(client.awaitRetirement(3000), "hung exit retired on host");
            }
            untilDead(p.get(), mode + " child cleaned up");
        }
        // Simulate an implementation where both destroy methods are ineffective.
        FakeProcess resistant = new FakeProcess(join(frame(utf(HELLO)), new byte[0])) {
            @Override public synchronized void destroy() { /* deliberately no effect */ }
            @Override public Process destroyForcibly() { return this; }
            synchronized void exitNow() { alive = false; notifyAll(); }
        };
        OwnedEclProcess uncertain = new OwnedEclProcess(() -> resistant, 1000);
        fails(IOException.class, () -> uncertain.request("{}", 1000), "resistant process exchange fails");
        ok(!uncertain.awaitRetirement(250), "no false forced-retirement guarantee");
        synchronized (resistant) { resistant.alive = false; resistant.notifyAll(); }
        ok(uncertain.awaitRetirement(1000), "retained ownership until eventual exit");
    }
    private static void nativeForcedRetirementHostOnly() throws Exception {
        for (boolean ignoresTerm : new boolean[]{false, true}) {
            AtomicReference<Process> owned = new AtomicReference<>();
            OwnedEclProcess client = new OwnedEclProcess(() -> {
                Process p = ignoresTerm ? launch("STUB_IGNORE_TERM", "1") : launch();
                owned.set(p); return p;
            }, 3000);
            if (ignoresTerm) {
                fails(IOException.class, () -> client.request("hang", 100), "SIGTERM-ignoring host child request deadline");
            } else {
                ok(client.request("stop-hang", 1000).equals("ok"), "test stub hanging-stop setup");
                fails(IOException.class, () -> client.close(100), "native stop deadline");
            }
            ok(client.awaitRetirement(3000), "actual host child retirement observed");
            untilDead(owned.get(), "retired exact owned host child");
        }
    }
    private static void blockingDestroyDoesNotBlockObservation() throws Exception {
        CountDownLatch destroyEntered = new CountDownLatch(1), releaseDestroy = new CountDownLatch(1), forceEntered = new CountDownLatch(1);
        FakeProcess blocked = new FakeProcess(frame(utf(HELLO))) {
            @Override public void destroy() {
                destroyEntered.countDown();
                try { releaseDestroy.await(); } catch (InterruptedException e) { Thread.currentThread().interrupt(); }
            }
            @Override public Process destroyForcibly() {
                forceEntered.countDown();
                synchronized (this) { alive = false; notifyAll(); }
                return this;
            }
        };
        OwnedEclProcess client = new OwnedEclProcess(() -> blocked, 1000);
        try {
            fails(IOException.class, () -> client.request("{}", 1000), "blocking-destroy retirement trigger");
            ok(destroyEntered.await(1000, TimeUnit.MILLISECONDS), "gentle destroy entered");
            ok(forceEntered.await(1000, TimeUnit.MILLISECONDS), "blocking destroy did not skip escalation");
            ok(client.awaitRetirement(1000), "blocking destroy did not block actual-exit observation");
        } finally { releaseDestroy.countDown(); }
    }
    private static void noExpiredDispatch() throws Exception {
        FakeProcess process = new FakeProcess(frame(utf(HELLO)));
        OwnedEclProcess client = new OwnedEclProcess(() -> process, 1000);
        java.lang.reflect.Field field = OwnedEclProcess.class.getDeclaredField("io");
        field.setAccessible(true);
        java.util.concurrent.ExecutorService io = (java.util.concurrent.ExecutorService) field.get(client);
        CountDownLatch held = new CountDownLatch(1), release = new CountDownLatch(1);
        io.submit(() -> { held.countDown(); try { release.await(); } catch (InterruptedException e) { Thread.currentThread().interrupt(); } });
        held.await();
        fails(IOException.class, () -> client.request("must-not-send", 40), "deadline while waiting for worker");
        release.countDown();
        ok(client.awaitRetirement(1000), "expired admission child retired");
        ok(io.awaitTermination(1000, TimeUnit.MILLISECONDS), "expired queued task settled");
        ok(process.output.size() == 0, "no frame after expired admission");
        FakeProcess interrupted = new FakeProcess(frame(utf(HELLO)));
        OwnedEclProcess next = new OwnedEclProcess(() -> interrupted, 1000);
        Thread.currentThread().interrupt();
        fails(InterruptedException.class, () -> next.request("must-not-send", 1000), "pre-interrupted request");
        ok(next.awaitRetirement(1000), "interrupted admission retired");
        ok(interrupted.output.size() == 0, "pre-interrupted request sent no frame");
        java.util.concurrent.atomic.AtomicBoolean launched = new java.util.concurrent.atomic.AtomicBoolean();
        Thread.currentThread().interrupt();
        fails(InterruptedException.class, () -> new OwnedEclProcess(() -> { launched.set(true); return interrupted; }, 1000), "pre-interrupted construction");
        ok(!launched.get(), "pre-interrupted constructor did not launch");
        fails(IOException.class, () -> new OwnedEclProcess(() -> { throw new IOException("test launch failure"); }, 1000), "launch failure");
        // A valid stop ack followed by a nonzero exit cannot be reported graceful.
        FakeProcess nonzero = new FakeProcess(join(frame(utf(HELLO)), new byte[4])) {
            @Override public synchronized int waitFor() { alive = false; return 23; }
            @Override public synchronized int exitValue() { alive = false; return 23; }
        };
        OwnedEclProcess badExit = new OwnedEclProcess(() -> nonzero, 1000);
        fails(IOException.class, () -> badExit.close(1000), "nonzero exit after stop ack");
        ok(badExit.awaitRetirement(1000), "nonzero exit cleanup");
    }
    public static void main(String[] args) throws Exception {
        libraries = new File(args[0]).getCanonicalFile(); runtime = new File(args[1]).getCanonicalFile();
        Files.createDirectories(runtime.toPath());
        unicodeAndBounds(); malformedResponses(); deadlinesAndAdmission(); retainedCreatorAndShutdown(); noExpiredDispatch(); nativeForcedRetirementHostOnly(); blockingDestroyDoesNotBlockObservation();
        System.out.println("PASS " + checks + " host JVM/C-ABI-STUB transport assertions; NO ECL/ART proof");
    }
}
