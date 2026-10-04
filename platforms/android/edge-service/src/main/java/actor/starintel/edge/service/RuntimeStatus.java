package actor.starintel.edge.service;

import android.content.Context;

/** Persist only redacted diagnostic enums. Persisted RUNNING never proves a live process. */
public final class RuntimeStatus {
    private static volatile String current = "STOPPED";
    private RuntimeStatus() {}
    public static String current() { return current; }
    public static String previous(Context context) {
        return context.getSharedPreferences("edge-status", Context.MODE_PRIVATE)
                .getString("last", "No earlier session");
    }
    static void persistBeforeExit(Context context) {
        context.getSharedPreferences("edge-status", Context.MODE_PRIVATE).edit()
                .putString("last", current).commit();
    }
    static void timedOut(Context context) {
        current = "FAILED: NATIVE_LIFECYCLE_TIMEOUT";
        // The watchdog is about to end its own runtime process. Persist before exit.
        context.getSharedPreferences("edge-status", Context.MODE_PRIVATE).edit()
                .putString("last", current).commit();
    }
    static void publish(Context context, RuntimeController.Snapshot snapshot) {
        current = snapshot.state.name() + (snapshot.reason == RuntimeController.Reason.NONE
                ? "" : ": " + snapshot.reason.name());
        context.getSharedPreferences("edge-status", Context.MODE_PRIVATE).edit()
                .putString("last", current).apply();
    }
}
