package actor.starintel.edge.diagnostic;

import android.Manifest;
import android.app.Activity;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.content.ComponentName;
import android.content.Intent;
import android.content.ServiceConnection;
import android.content.pm.PackageManager;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.IBinder;
import android.os.Looper;
import android.os.Message;
import android.os.Messenger;
import android.os.RemoteException;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.TextView;
import actor.starintel.edge.service.EdgeRuntimeService;

/** Plain local diagnostic UX. Live status comes from the private runtime process over IPC. */
public final class MainActivity extends Activity {
    private final Handler main = new Handler(Looper.getMainLooper());
    private TextView status;
    private TextView notice;
    private boolean visible;
    private boolean binding;
    private int generation;
    private Messenger runtime;
    private final Messenger replies = new Messenger(new Handler(Looper.getMainLooper(), message -> {
        if (!visible || runtime == null || message.what != EdgeRuntimeService.STATUS
                || message.arg1 != generation) return true;
        Bundle data = message.getData();
        status.setText("Live runtime process: " + data.getString("current", "UNKNOWN")
                + "\nLast recorded session: " + data.getString("previous", "Unknown")
                + "\nA past RUNNING record does not mean a server is live.");
        return true;
    }));
    private final ServiceConnection connection = new ServiceConnection() {
        @Override public void onServiceConnected(ComponentName name, IBinder service) {
            if (visible && binding) runtime = new Messenger(service);
        }
        @Override public void onServiceDisconnected(ComponentName name) { disconnect(); }
        @Override public void onBindingDied(ComponentName name) { disconnect(); }
        @Override public void onNullBinding(ComponentName name) { disconnect(); }
    };
    private final Runnable refresh = new Runnable() {
        @Override public void run() {
            if (!visible) return;
            if (!binding) binding = bindService(new Intent(MainActivity.this, EdgeRuntimeService.class), connection, BIND_AUTO_CREATE);
            if (runtime == null) status.setText("No live runtime connection. Stopped, starting or unavailable.");
            else {
                Message request = Message.obtain(null, EdgeRuntimeService.STATUS);
                request.arg1 = generation;
                request.replyTo = replies;
                try { runtime.send(request); } catch (RemoteException stopped) { disconnect(); }
            }
            main.postDelayed(this, 1000);
        }
    };
    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        LinearLayout view = new LinearLayout(this);
        view.setOrientation(LinearLayout.VERTICAL);
        int padding = (int) (24 * getResources().getDisplayMetrics().density);
        view.setPadding(padding, padding, padding, padding);
        TextView title = new TextView(this);
        title.setText("StarIntel Edge • Android host preview");
        title.setTextSize(23);
        view.addView(title);
        TextView explanation = new TextView(this);
        explanation.setText("This service uses the existing ECL/JNI local Lisp actor core when its runtime bundle is packaged. Missing libraries report BACKEND_MISSING. Full star-server HTTP/CouchDB/RabbitMQ is not included.\n\n"
                + "A real runtime will keep a visible notification with Stop, preserve private init.lisp, and require a new explicit Start after process death or reboot. Android can still stop it or restrict networking.\n");
        view.addView(explanation);
        status = new TextView(this); view.addView(status);
        notice = new TextView(this); view.addView(notice);
        Button start = new Button(this); start.setText("Start local runtime");
        start.setOnClickListener(v -> requestStart()); view.addView(start);
        Button stop = new Button(this); stop.setText("Stop");
        stop.setOnClickListener(v -> startService(new Intent(this, EdgeRuntimeService.class)
                .setAction(EdgeRuntimeService.STOP))); view.addView(stop);
        setContentView(view);
    }
    private void requestStart() {
        if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS)
                != PackageManager.PERMISSION_GRANTED) {
            notice.setText("Allow notifications to keep the runtime and its Stop control visible. After granting permission, tap Start again.");
            requestPermissions(new String[]{Manifest.permission.POST_NOTIFICATIONS}, 1);
            return;
        }
        NotificationManager manager = getSystemService(NotificationManager.class);
        NotificationChannel channel = manager.getNotificationChannel(EdgeRuntimeService.CHANNEL);
        if (!manager.areNotificationsEnabled() || (channel != null
                && channel.getImportance() == NotificationManager.IMPORTANCE_NONE)) {
            notice.setText("Enable the runtime notification in Android settings, then tap Start.");
            return;
        }
        try {
            startForegroundService(new Intent(this, EdgeRuntimeService.class).setAction(EdgeRuntimeService.START));
            notice.setText("Start requested. Backend readiness is reported separately.");
        } catch (RuntimeException denied) {
            notice.setText("Android did not allow the foreground service to start. Keep this screen open and check notification settings.");
        }
    }
    private void disconnect() {
        runtime = null;
        generation++;
        if (binding) {
            binding = false;
            unbindService(connection);
        }
        if (status != null) status.setText("Runtime connection ended. Start explicitly to try again.");
    }
    @Override public void onResume() { super.onResume(); visible = true; main.post(refresh); }
    @Override public void onPause() {
        visible = false;
        main.removeCallbacks(refresh);
        disconnect();
        super.onPause();
    }
}
