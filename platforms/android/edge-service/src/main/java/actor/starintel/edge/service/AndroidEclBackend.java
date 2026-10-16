package actor.starintel.edge.service;

import android.content.Context;
import android.content.res.AssetManager;
import java.io.File;
import java.io.InputStream;
import java.io.IOException;
import org.json.JSONObject;

/** ART owns a bounded pipe client; only its standalone child loads ECL. */
final class AndroidEclBackend implements LocalRuntimeBackend {
    private final EclLifecycle lifecycle;
    AndroidEclBackend(Context context) {
        AssetManager assets = context.getApplicationContext().getAssets();
        File libraries = new File(context.getApplicationInfo().nativeLibraryDir);
        lifecycle = new EclLifecycle(new OwnedEclNativePort(libraries, new OwnedEclNativePort.Responses() {
            @Override public boolean ready(String pingText, String stateText, String actorText) throws Exception {
                JSONObject ping = new JSONObject(pingText);
                JSONObject state = new JSONObject(stateText);
                JSONObject actor = new JSONObject(actorText);
                return ping.getString("status").equals("ok") && ping.getInt("adapter-abi") == 1
                        && ping.getString("runtime").equals("starintel-edge")
                        && state.getString("status").equals("ok") && state.getString("state").equals("running")
                        && state.getString("profile").equals("local-actors") && state.getString("init").equals("loaded")
                        && actor.getString("status").equals("ok")
                        && actor.getString("message").equals("android-local");
            }
            @Override public boolean stopped(String text) throws Exception {
                JSONObject result = new JSONObject(text);
                return result.getString("status").equals("ok") && result.getString("state").equals("stopped");
            }
        }), new RuntimeAssets(new RuntimeAssets.Source() {
            @Override public String[] list(String path) throws IOException { return assets.list(path); }
            @Override public InputStream open(String path) throws IOException { return assets.open(path); }
        }));
    }
    @Override public boolean requiresFreshProcess() { return lifecycle.requiresFreshProcess(); }
    @Override public Session open(Config config, Cancellation cancellation) throws Exception {
        return lifecycle.open(config, cancellation);
    }
}
