package actor.starintel.edge.service;

import java.io.Closeable;
import java.io.DataInputStream;
import java.io.DataOutputStream;
import java.io.File;
import java.io.IOException;
import java.io.InputStream;
import java.nio.ByteBuffer;
import java.nio.CharBuffer;
import java.nio.charset.CharacterCodingException;
import java.nio.charset.CodingErrorAction;
import java.nio.charset.StandardCharsets;
import java.util.concurrent.Callable;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.TimeoutException;
import java.util.concurrent.atomic.AtomicBoolean;

/** Experimental transport only. Never selects an Android backend or claims
 * Lisp service readiness. One client owns one child, without restart or retry.
 */
public final class OwnedEclProcess implements Closeable {
    private static final int MAX_REQUEST = 1024 * 1024;
    private static final int MAX_RESPONSE = 4 * 1024 * 1024;
    private static final String HELLO = "{\"transport\":\"starintel-owned/1\",\"abi\":1}";
    private final Object ownership = new Object();
    private final AtomicBoolean admitted = new AtomicBoolean();
    // This thread creates the child and is retained until actual child exit.
    // Never replace with a transient caller thread: Linux PDEATHSIG is per creator.
    private final ExecutorService io = Executors.newSingleThreadExecutor(r -> daemon(r, "edge-owned-io"));
    private final long defaultTimeoutMillis;
    private volatile boolean closed, gracefulClosed;
    private Process child; // Access under ownership, including late publication.
    private boolean launchFinished, reaperStarted, retirementConfirmed;
    private DataInputStream input; // Worker-only streams.
    private DataOutputStream output;

    @FunctionalInterface interface Launcher { Process start() throws IOException; }

    /** Android must supply ApplicationInfo.nativeLibraryDir, with an extracted,
     * executable PIE libstarintel_ecl_runner.so and its packaged sibling DSOs.
     * No app-home binary copying or execution is provided. Packaging/ART gates
     * are deliberately separate. Directory is trusted platform configuration.
     */
    public static OwnedEclProcess start(File packagedNativeLibraryDirectory,
                                       File runtimeDirectory, long timeoutMillis)
            throws IOException, InterruptedException {
        File libraries = packagedNativeLibraryDirectory.getCanonicalFile();
        File runtime = runtimeDirectory.getCanonicalFile();
        File runner = new File(libraries, "libstarintel_ecl_runner.so").getCanonicalFile();
        encode(libraries.getPath(), 4096);
        encode(runtime.getPath(), 4096);
        if (!libraries.isDirectory() || libraries.getPath().indexOf(':') >= 0 ||
                !runner.getParentFile().equals(libraries) || !runner.isFile() || !runner.canExecute() ||
                !runtime.isDirectory()) throw new IOException("Packaged runtime paths unavailable");
        return new OwnedEclProcess(() -> {
            ProcessBuilder builder = new ProcessBuilder(runner.getPath(), runtime.getPath());
            // Explicit child-only dependency search. Never load ECL into ART.
            builder.environment().put("LD_LIBRARY_PATH", libraries.getPath());
            builder.environment().remove("LD_PRELOAD");
            builder.environment().remove("LD_AUDIT");
            return builder.start();
        }, timeoutMillis);
    }

    /* Package-private seam for host ownership tests, not a request command surface. */
    OwnedEclProcess(Launcher launcher, long timeoutMillis) throws IOException, InterruptedException {
        long deadline = deadline(timeoutMillis);
        defaultTimeoutMillis = timeoutMillis;
        if (Thread.interrupted()) { io.shutdown(); throw new InterruptedException(); }
        Future<Void> launch = io.submit(() -> {
            try {
                if (closed) throw new IOException("Launch abandoned");
                remaining(deadline);
                Process created = launcher.start();
                synchronized (ownership) {
                    child = created; // Publish even after the caller has timed out.
                    ownership.notifyAll();
                }
                drain(created.getErrorStream());
                if (closed) throw new IOException("Launch abandoned");
                input = new DataInputStream(created.getInputStream());
                output = new DataOutputStream(created.getOutputStream());
                if (!HELLO.equals(readFrame())) throw new IOException("Child transport handshake mismatch");
                return null;
            } finally {
                synchronized (ownership) { launchFinished = true; ownership.notifyAll(); }
            }
        });
        try { await(launch, deadline); }
        catch (IOException | InterruptedException failure) { retire(); throw failure; }
    }

    public String request(String request, long timeoutMillis) throws IOException, InterruptedException {
        long deadline = deadline(timeoutMillis);
        admit();
        try {
            byte[] bytes = encode(request, MAX_REQUEST);
            if (bytes.length == 0) throw new IOException("Empty request is reserved for shutdown");
            return exchange(() -> {
                output.writeInt(bytes.length); output.write(bytes); output.flush();
                return readFrame();
            }, deadline);
        } finally { admitted.set(false); }
    }

    @Override public void close() throws IOException {
        try { close(defaultTimeoutMillis); }
        catch (InterruptedException interrupted) {
            Thread.currentThread().interrupt();
            throw new IOException("Interrupted while stopping owned child", interrupted);
        }
    }

    /** Success requires the zero-length acknowledgement AND an actual zero exit. */
    public void close(long timeoutMillis) throws IOException, InterruptedException {
        long deadline = deadline(timeoutMillis);
        if (gracefulClosed) return;
        admit();
        try {
            exchange(() -> {
                output.writeInt(0); output.flush();
                if (input.readInt() != 0) throw new IOException("Invalid stop acknowledgement");
                Process process;
                synchronized (ownership) { process = child; }
                if (!process.waitFor(remaining(deadline), TimeUnit.NANOSECONDS))
                    throw new IOException("Child did not exit after stop acknowledgement");
                if (process.exitValue() != 0) throw new IOException("Child exited unsuccessfully");
                synchronized (ownership) {
                    closed = true; gracefulClosed = true; retirementConfirmed = true; ownership.notifyAll();
                }
                releaseStreams(process);
                io.shutdown();
                return null;
            }, deadline);
        } finally { admitted.set(false); }
    }

    /** Bounded observation after a failed exchange. True means actual exit (or
     * launch failed without a child). False means retirement is UNCONFIRMED.
     * destroyForcibly is a best effort: Android/ART may not implement SIGKILL.
     */
    public boolean awaitRetirement(long timeoutMillis) throws InterruptedException {
        long end = deadline(timeoutMillis);
        synchronized (ownership) {
            while (!retirementConfirmed) {
                long left = end - System.nanoTime();
                if (left <= 0) return false;
                TimeUnit.NANOSECONDS.timedWait(ownership, left);
            }
            return true;
        }
    }

    private void admit() {
        if (!admitted.compareAndSet(false, true)) throw new IllegalStateException("Exchange already in progress");
        if (closed) { admitted.set(false); throw new IllegalStateException("Owned child is closed"); }
    }

    private <T> T exchange(Callable<T> operation, long deadline) throws IOException, InterruptedException {
        try {
            if (Thread.interrupted()) throw new InterruptedException();
            remaining(deadline);
            Future<T> future = io.submit(() -> {
                if (closed) throw new IOException("Owned child is closed");
                remaining(deadline); // A queued task must not send after its caller times out.
                return operation.call();
            });
            return await(future, deadline);
        } catch (IOException | InterruptedException failure) { retire(); throw failure; }
    }

    private static <T> T await(Future<T> future, long deadline) throws IOException, InterruptedException {
        try { return future.get(remaining(deadline), TimeUnit.NANOSECONDS); }
        catch (TimeoutException timedOut) { throw new IOException("Owned child deadline exceeded; retirement requested", timedOut); }
        catch (ExecutionException failed) { throw new IOException("Owned child exchange failed; retirement requested", failed.getCause()); }
        // Do not cancel: an in-flight ProcessBuilder.start must publish its late child.
    }

    private String readFrame() throws IOException {
        int length = input.readInt();
        if (length <= 0 || length > MAX_RESPONSE) throw new IOException("Invalid response length");
        byte[] bytes = new byte[length]; input.readFully(bytes);
        for (byte value : bytes) if (value == 0) throw new IOException("Literal NUL response");
        try {
            return StandardCharsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT)
                    .onUnmappableCharacter(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(bytes)).toString();
        } catch (CharacterCodingException invalid) { throw new IOException("Invalid response UTF-8", invalid); }
    }

    private static byte[] encode(String value, int limit) throws IOException {
        if (value == null || value.length() > limit || value.indexOf('\0') >= 0)
            throw new IOException("Invalid bounded UTF-8 input");
        try {
            ByteBuffer bytes = StandardCharsets.UTF_8.newEncoder().onMalformedInput(CodingErrorAction.REPORT)
                    .onUnmappableCharacter(CodingErrorAction.REPORT).encode(CharBuffer.wrap(value));
            if (bytes.remaining() > limit) throw new IOException("UTF-8 input exceeds byte limit");
            byte[] result = new byte[bytes.remaining()]; bytes.get(result); return result;
        } catch (CharacterCodingException invalid) { throw new IOException("Invalid input Unicode", invalid); }
    }

    private static long deadline(long millis) {
        if (millis < 1 || millis > 300_000) throw new IllegalArgumentException("Deadline must be 1..300000 ms");
        return System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(millis);
    }
    private static long remaining(long deadline) throws IOException {
        long left = deadline - System.nanoTime();
        if (left <= 0) throw new IOException("Owned child deadline exceeded; retirement requested");
        return left;
    }
    private static Thread daemon(Runnable work, String name) {
        Thread thread = new Thread(work, name); thread.setDaemon(true); return thread;
    }
    private static void drain(InputStream stream) {
        daemon(() -> {
            // Trusted-init diagnostics may contain private data: discard, never log or retain.
            try (InputStream error = stream) { byte[] buffer = new byte[8192]; while (error.read(buffer) != -1) {} }
            catch (IOException ignored) { /* Child exit or stream failure. */ }
        }, "edge-owned-stderr").start();
    }

    private static void releaseStreams(Process process) {
        daemon(() -> {
            for (Closeable stream : new Closeable[]{process.getOutputStream(), process.getInputStream(), process.getErrorStream()}) {
                try { stream.close(); } catch (IOException ignored) { /* Exited child. */ }
            }
        }, "edge-owned-stream-cleanup").start();
    }

    private void retire() {
        synchronized (ownership) {
            closed = true;
            if (reaperStarted) return;
            reaperStarted = true;
        }
        // Separate from blocked I/O, and never block a caller past its exchange deadline.
        daemon(() -> {
            Process owned;
            try {
                synchronized (ownership) {
                    while (child == null && !launchFinished) ownership.wait();
                    owned = child;
                }
                if (owned != null) {
                    // Process.destroy may itself block while closing a pipe stream.
                    // Separate attempts from each other and from exit observation.
                    daemon(() -> {
                        try { owned.destroy(); } catch (RuntimeException ignored) { /* Best effort. */ }
                    }, "edge-owned-destroy").start();
                    daemon(() -> {
                        try {
                            Thread.sleep(100);
                            if (owned.isAlive()) owned.destroyForcibly();
                        } catch (InterruptedException interrupted) { Thread.currentThread().interrupt(); }
                        catch (RuntimeException ignored) { /* Exit remains unconfirmed. */ }
                    }, "edge-owned-force").start();
                    // No claimed hard-kill guarantee. Retain ownership and creator thread
                    // until actual exit, even if this wait takes indefinitely on ART.
                    owned.waitFor();
                    releaseStreams(owned);
                }
                synchronized (ownership) { retirementConfirmed = true; ownership.notifyAll(); }
                io.shutdown();
            } catch (InterruptedException interrupted) {
                Thread.currentThread().interrupt(); // Retirement remains unconfirmed.
            }
        }, "edge-owned-retirement").start();
    }
}
