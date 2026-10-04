package actor.starintel.edge.service;

import android.Manifest;
import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Intent;
import android.content.Context;
import java.util.function.Consumer;
import android.content.pm.PackageManager;
import android.content.pm.ServiceInfo;
import android.os.Build;
import android.os.Handler;
import android.os.IBinder;
import android.os.Looper;
import android.os.Message;
import android.os.Messenger;
import android.os.Bundle;
import android.os.RemoteException;
import java.io.File;
import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.io.IOException;

/** Foreground platform host reusing the packaged ECL/JNI backend, never a remote proxy. */
public class EdgeRuntimeService extends Service {
    public static final String START = "actor.starintel.edge.START";
    public static final String STOP = "actor.starintel.edge.STOP";
    public static final String CHANNEL = "edge-runtime";
    public static final int STATUS = 1;
    private final Messenger messenger = new Messenger(new Handler(Looper.getMainLooper(), message -> {
        if (message.what != STATUS || message.replyTo == null) return false;
        Message response = Message.obtain(null, STATUS);
        response.arg1 = message.arg1;
        Bundle data = new Bundle();
        data.putString("current", RuntimeStatus.current());
        data.putString("previous", RuntimeStatus.previous(this));
        response.setData(data);
        try { message.replyTo.send(response); } catch (RemoteException disconnected) { /* No subscriber. */ }
        return true;
    }));
    private static final int NOTIFICATION = 5701;
    private final Handler main = new Handler(Looper.getMainLooper());
    private RuntimeController controller;
    private RuntimeOwner owner;
    private final Consumer<RuntimeController.Snapshot> stateListener = this::onRuntimeState;
    private int lastStartId;
    private boolean destroyed;
    private boolean foreground;
    private final Runnable visibilityCheck = new Runnable() {
        @Override public void run() {
            if (destroyed || !foreground) return;
            if (!notificationsVisible()) controller.stop();
            if (controller.snapshot().active()) main.postDelayed(this, 5000);
        }
    };

    /** Build-time composition only. Do not load arbitrary class names or code from intents. */
    protected LocalRuntimeBackend createBackend() { return new AndroidEclBackend(getApplicationContext()); }

    @Override public void onCreate() {
        super.onCreate();
        NotificationManager manager = getSystemService(NotificationManager.class);
        manager.createNotificationChannel(new NotificationChannel(CHANNEL,
                "StarIntel local runtime", NotificationManager.IMPORTANCE_LOW));
        Context application = getApplicationContext();
        owner = RuntimeOwner.acquire(application, () -> {
            LocalRuntimeBackend backend = createBackend();
            return new LocalRuntimeBackend() {
                @Override public boolean requiresFreshProcess() { return backend.requiresFreshProcess(); }
                @Override public Session open(Config config, Cancellation cancellation) throws Exception {
                    cancellation.check();
                    // Executable operator-controlled Lisp, never request/config data.
                    PrivateInitFile.ensure(config.privateDirectory, readInitTemplate(application));
                    cancellation.check();
                    return backend.open(config, cancellation);
                }
            };
        });
        controller = owner.controller;
        owner.attach(stateListener);
    }
    @Override public int onStartCommand(Intent intent, int flags, int startId) {
        lastStartId = startId;
        if (intent == null || (!START.equals(intent.getAction()) && !STOP.equals(intent.getAction()))) {
            if (!controller.snapshot().active()) stopSelfResult(startId);
            return START_NOT_STICKY;
        }
        if (STOP.equals(intent.getAction())) {
            if (!controller.stop()) finishIfIdle();
            return START_NOT_STICKY;
        }
        // A replacement Service may observe cleanup still owned by the previous instance.
        // It must satisfy foreground launch timing, but must not start a second backend.
        // A visible notification is an app requirement even where Android does not require it.
        if (!notificationsVisible()) {
            rejectForegroundStart(startId);
            return START_NOT_STICKY;
        }
        try {
            Notification notification = notification(controller.snapshot().active()
                    ? RuntimeStatus.current() : "Starting local Lisp runtime");
            if (Build.VERSION.SDK_INT >= 34) startForeground(NOTIFICATION, notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE);
            else startForeground(NOTIFICATION, notification);
            foreground = true;
            main.removeCallbacks(visibilityCheck);
            main.postDelayed(visibilityCheck, 5000);
            File directory = new File(getNoBackupFilesDir(), "runtime");
            controller.start(new LocalRuntimeBackend.Config(directory, new File(directory, "init.lisp")));
        } catch (RuntimeException denied) {
            // Includes foreground-start/type/permission restrictions. No error text is persisted.
            rejectForegroundStart(startId);
        }
        return START_NOT_STICKY;
    }
    private void rejectForegroundStart(int startId) {
        controller.stop(); // Process owner completes cleanup independently, with its watchdog.
        stopForeground(STOP_FOREGROUND_REMOVE);
        foreground = false;
        main.removeCallbacks(visibilityCheck);
        stopSelfResult(startId); // Cancel this launch now; never wait for slow native cleanup.
    }
    private boolean notificationsVisible() {
        if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS)
                != PackageManager.PERMISSION_GRANTED) return false;
        NotificationManager manager = getSystemService(NotificationManager.class);
        NotificationChannel channel = manager.getNotificationChannel(CHANNEL);
        return manager.areNotificationsEnabled() && channel != null
                && channel.getImportance() != NotificationManager.IMPORTANCE_NONE;
    }
    private Notification notification(String status) {
        Intent stop = new Intent(this, getClass()).setAction(STOP);
        PendingIntent action = PendingIntent.getService(this, 1, stop,
                PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
        Notification.Builder builder = new Notification.Builder(this, CHANNEL)
                .setSmallIcon(R.drawable.ic_edge_runtime)
                .setContentTitle("StarIntel local runtime")
                .setContentText(status)
                .setOngoing(true).setOnlyAlertOnce(true)
                .setCategory(Notification.CATEGORY_SERVICE)
                .addAction(new Notification.Action.Builder(null, "Stop", action).build());
        Intent launcher = getPackageManager().getLaunchIntentForPackage(getPackageName());
        if (launcher != null) builder.setContentIntent(PendingIntent.getActivity(this, 2, launcher,
                PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE));
        return builder.build();
    }
    private void onRuntimeState(RuntimeController.Snapshot snapshot) {
        if (destroyed || snapshot != controller.snapshot()) return; // Ignore stale startup callbacks.
        if (snapshot.active()) {
            if (foreground) getSystemService(NotificationManager.class).notify(NOTIFICATION,
                    notification(snapshot.state == RuntimeController.State.RUNNING
                            ? "Local Lisp runtime running" : RuntimeStatus.current()));
        } else finishIfIdle();
    }
    private void finishIfIdle() {
        if (controller.snapshot().active()) return;
        stopForeground(STOP_FOREGROUND_REMOVE);
        foreground = false;
        main.removeCallbacks(visibilityCheck);
        stopSelfResult(lastStartId);
    }
    @Override public void onDestroy() {
        destroyed = true;
        owner.detachAndStop(stateListener);
        main.removeCallbacksAndMessages(null);
        super.onDestroy();
    }
    @Override public IBinder onBind(Intent intent) { return messenger.getBinder(); }

    private static byte[] readInitTemplate(Context context) throws IOException {
        try (InputStream input = context.getAssets().open("starintel-edge-host/init.lisp");
             ByteArrayOutputStream output = new ByteArrayOutputStream()) {
            byte[] buffer = new byte[4096];
            int count;
            while ((count = input.read(buffer)) != -1) {
                if (output.size() + count > 1024 * 1024) throw new IOException("Init template too large");
                output.write(buffer, 0, count);
            }
            return output.toByteArray();
        }
    }
}
