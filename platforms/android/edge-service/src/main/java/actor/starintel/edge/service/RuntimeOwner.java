package actor.starintel.edge.service;

import android.app.ActivityManager;
import android.app.Application;
import android.content.Context;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.os.Process;
import java.util.function.Consumer;
import java.util.function.Supplier;

/** One private runtime process owns ECL and its stable native thread across Service instances. */
final class RuntimeOwner {
    private static RuntimeOwner instance;
    private final Handler main = new Handler(Looper.getMainLooper());
    private final Context application;
    final RuntimeController controller;
    private Consumer<RuntimeController.Snapshot> listener;
    private Runnable timeout;
    private boolean retiring;

    static synchronized RuntimeOwner acquire(Context context, Supplier<LocalRuntimeBackend> factory) {
        if (instance == null) instance = new RuntimeOwner(context.getApplicationContext(), factory.get());
        return instance;
    }
    private RuntimeOwner(Context context, LocalRuntimeBackend backend) {
        application = context;
        controller = new RuntimeController(backend, this::enqueueSnapshot);
    }
    private void enqueueSnapshot(RuntimeController.Snapshot snapshot) {
        main.post(() -> {
            if (snapshot != controller.snapshot()) return;
            RuntimeStatus.publish(application, snapshot);
            if (timeout != null) main.removeCallbacks(timeout);
            timeout = null;
            if (snapshot.state == RuntimeController.State.STARTING
                    || snapshot.state == RuntimeController.State.STOPPING
                    || snapshot.reason == RuntimeController.Reason.STOP_FAILED) {
                timeout = () -> {
                    if (snapshot != controller.snapshot() || !isOwnedRuntimeProcess()) return;
                    RuntimeStatus.timedOut(application);
                    // No PID is accepted from IPC/config. This cannot kill the UI or another app.
                    Process.killProcess(Process.myPid());
                };
                main.postDelayed(timeout, snapshot.state == RuntimeController.State.STARTING ? 30000 : 10000);
            }
            if (listener != null) listener.accept(snapshot);
            if (!snapshot.active() && controller.requiresFreshProcess() && !retiring) {
                retiring = true;
                RuntimeStatus.persistBeforeExit(application);
                // Let the stop notification/status reach the UI, then retire this ECL lifetime.
                // AUTO_CREATE may bind a fresh idle process; it never invokes Lisp Start.
                main.postDelayed(() -> {
                    if (isOwnedRuntimeProcess()) Process.killProcess(Process.myPid());
                }, 500);
            }
        });
    }
    private boolean isOwnedRuntimeProcess() {
        String expected = application.getPackageName() + ":starintel_runtime";
        if (Build.VERSION.SDK_INT >= 28) return expected.equals(Application.getProcessName());
        ActivityManager manager = application.getSystemService(ActivityManager.class);
        java.util.List<ActivityManager.RunningAppProcessInfo> running = manager.getRunningAppProcesses();
        if (running != null) for (ActivityManager.RunningAppProcessInfo process : running) {
            if (process.pid == Process.myPid()) return expected.equals(process.processName);
        }
        return false; // Never guess the process identity.
    }
    void attach(Consumer<RuntimeController.Snapshot> listener) { this.listener = listener; }
    void detachAndStop(Consumer<RuntimeController.Snapshot> owner) {
        if (listener == owner) {
            listener = null;
            controller.stop();
        }
    }
}
