package actor.starintel.edge.service;

import android.app.Activity;
import android.os.Bundle;
import android.util.Log;
import android.widget.TextView;
import java.io.File;
import java.io.FileOutputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;

/** Disposable APK only, no network permission. Executes the production backend. */
public final class RuntimeDiagnosticActivity extends Activity {
    private static final String TAG = "StarIntelEdgeDiagnostic";
    // Trusted synthetic init, never supplied by IPC or runtime requests. A state
    // sentinel is read by real Lisp on EVERY boot; Java verifies it remains intact.
    private static final String INIT = "(in-package :cl-user)\n"
            + "(with-open-file (s (merge-pathnames \"fixture-state.txt\" *default-pathname-defaults*))\n"
            + "  (unless (string= (read-line s) \"synthetic-preserved-state\") (error \"fixture-state-lost\")))\n";
    private static final byte[] STATE = "synthetic-preserved-state\n".getBytes(StandardCharsets.UTF_8);
    // Activity recreation must not launch a second worker against the same data.
    // The harness kills this ART process between phases, resetting this owner.
    private static final java.util.concurrent.atomic.AtomicBoolean launched = new java.util.concurrent.atomic.AtomicBoolean();
    private static LocalRuntimeBackend.Session held;
    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        TextView status = new TextView(this);
        status.setText("Running owned ECL acceptance…");
        setContentView(status);
        String phase = getIntent().getStringExtra("phase");
        if (!launched.compareAndSet(false, true)) {
            Log.i(TAG, "RECREATED " + phase + " existing process-owned diagnostic");
            return;
        }
        Log.i(TAG, "BEGIN " + phase + " pid=" + android.os.Process.myPid());
        new Thread(() -> {
            try {
                File root = new File(getNoBackupFilesDir(), "runtime");
                File init = new File(root, "init.lisp");
                File sentinel = new File(root, "fixture-state.txt");
                if ("measure".equals(phase)) {
                    // Separate bounded investigation after acceptance failed. Never
                    // emits READY/HOLD or changes the production startup deadline.
                    verify(init, sentinel);
                    long began = System.nanoTime();
                    OwnedEclProcess child = OwnedEclProcess.start(
                            new File(getApplicationInfo().nativeLibraryDir), root, 120000);
                    try {
                        Log.i(TAG, "MEASURE handshake-ms=" + (System.nanoTime() - began) / 1000000);
                        for (String operation : new String[]{"runtime.ping", "service.status", "actor.roundtrip", "service.stop"}) {
                            String reply = child.request("{\"op\":\"" + operation + "\"}", 5000);
                            Log.i(TAG, "MEASURE " + operation + " " + reply);
                        }
                    } finally {
                        child.close(5000);
                    }
                    verify(init, sentinel);
                    Log.i(TAG, "MEASURE_DONE synthetic probe only; production acceptance still failed");
                    return;
                }
                if ("first".equals(phase)) {
                    if (root.exists()) throw new IllegalStateException("Fresh APK data required");
                    if (!root.mkdirs()) throw new IllegalStateException("Private directory unavailable");
                    writeSynced(sentinel, STATE);
                    writeSynced(init, INIT.getBytes(StandardCharsets.UTF_8));
                } else if (!"restart".equals(phase)) {
                    throw new IllegalArgumentException("Explicit test phase required");
                }
                verify(init, sentinel);
                LocalRuntimeBackend.Config config = new LocalRuntimeBackend.Config(root, init);
                for (int i = 0; i < 2; i++) {
                    AndroidEclBackend backend = new AndroidEclBackend(this);
                    try (LocalRuntimeBackend.Session session = backend.open(config, new LocalRuntimeBackend.Cancellation())) {
                        Log.i(TAG, "READY " + phase + " cycle=" + i + " real Sento roundtrip; server-api unavailable");
                    }
                    verify(init, sentinel);
                    Log.i(TAG, "STOPPED " + phase + " cycle=" + i + " acknowledged zero child exit");
                }
                // Keep a real child live for the harness to kill this exact APK's
                // ART process. The next launch must preserve state and boot anew.
                held = new AndroidEclBackend(this).open(config, new LocalRuntimeBackend.Cancellation());
                verify(init, sentinel);
                Log.i(TAG, "HOLD " + phase + " local Sento ready; fixture state preserved");
                runOnUiThread(() -> status.setText("Local Sento actor round-trip passed; held for process-death test"));
            } catch (Throwable failure) {
                Log.e(TAG, "FAIL " + phase, failure);
                runOnUiThread(() -> status.setText("FAIL: " + failure.getClass().getSimpleName()));
            }
        }, "owned-ecl-acceptance").start();
    }
    private static void verify(File init, File sentinel) throws Exception {
        if (!java.util.Arrays.equals(Files.readAllBytes(init.toPath()), INIT.getBytes(StandardCharsets.UTF_8))
                || !java.util.Arrays.equals(Files.readAllBytes(sentinel.toPath()), STATE))
            throw new IllegalStateException("Private fixture changed across boot/stop/death");
    }
    private static void writeSynced(File path, byte[] value) throws Exception {
        try (FileOutputStream stream = new FileOutputStream(path)) {
            stream.write(value); stream.getFD().sync();
        }
    }
}
