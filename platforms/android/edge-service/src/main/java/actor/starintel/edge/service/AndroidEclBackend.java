package actor.starintel.edge.service;

import android.content.Context;
import android.content.res.AssetManager;
import actor.starintel.edge.StarIntelEdgeRuntime;
import java.io.InputStream;
import java.io.IOException;
import org.json.JSONObject;

/** Thin platform adapter to the existing pinned ECL runtime. All calls use the owner's one thread. */
final class AndroidEclBackend implements LocalRuntimeBackend {
    private final EclLifecycle lifecycle;
    AndroidEclBackend(Context context) {
        AssetManager assets = context.getApplicationContext().getAssets();
        lifecycle = new EclLifecycle(new EclLifecycle.NativePort() {
            @Override public int abiVersion() { return StarIntelEdgeRuntime.INSTANCE.abiVersion(); }
            @Override public String start(String directory) { return StarIntelEdgeRuntime.INSTANCE.start(directory); }
            @Override public boolean localServiceReady() {
                try {
                    JSONObject ping = new JSONObject(StarIntelEdgeRuntime.INSTANCE.request("{\"op\":\"runtime.ping\"}"));
                    JSONObject state = new JSONObject(StarIntelEdgeRuntime.INSTANCE.request("{\"op\":\"service.status\"}"));
                    return ping.getString("status").equals("ok") && ping.getInt("adapter-abi") == 1
                            && ping.getString("runtime").equals("starintel-edge")
                            && state.getString("status").equals("ok") && state.getString("state").equals("running")
                            && state.getString("profile").equals("local-actors") && state.getString("init").equals("loaded");
                } catch (Exception malformed) { return false; }
            }
            @Override public boolean stopManagedRuntime() {
                try {
                    JSONObject result = new JSONObject(StarIntelEdgeRuntime.INSTANCE.request("{\"op\":\"service.stop\"}"));
                    return result.getString("status").equals("ok") && result.getString("state").equals("stopped");
                } catch (Exception malformed) { return false; }
            }
            @Override public void stop() { StarIntelEdgeRuntime.INSTANCE.stop(); }
        }, new RuntimeAssets(new RuntimeAssets.Source() {
            @Override public String[] list(String path) throws IOException { return assets.list(path); }
            @Override public InputStream open(String path) throws IOException { return assets.open(path); }
        }));
    }
    @Override public boolean requiresFreshProcess() { return lifecycle.requiresFreshProcess(); }
    @Override public Session open(Config config, Cancellation cancellation) throws Exception {
        return lifecycle.open(config, cancellation);
    }
}
