package actor.interop;

import actor.starintel.edge.StarIntelEdgeRuntime;
import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.nio.charset.StandardCharsets;

/** Java calls the actual Kotlin singleton, production JNI, C adapter and ECL. */
public final class JavaActorClient {
    public static void main(String[] args) throws Exception {
        StarIntelEdgeRuntime runtime = StarIntelEdgeRuntime.INSTANCE;
        System.out.println("ACTOR_ABI\t" + runtime.abiVersion());
        String error = runtime.start(args[0]);
        if (error != null) throw new AssertionError("real ECL startup: " + error);
        try {
            BufferedReader reader = new BufferedReader(new InputStreamReader(System.in, StandardCharsets.UTF_8));
            String line;
            while ((line = reader.readLine()) != null)
                System.out.println("ACTOR_RESULT\t" + runtime.request(line));
            int checks = 0;
            for (String bad : new String[] {"x" + (char) 0 + "y", String.valueOf((char) 0xd800),
                    String.valueOf((char) 0xdc00), new String(new char[] {0xd800, 'a'})}) {
                String response = runtime.request("{\"op\":\"dispatch\",\"payload\":\"" + bad + "\",\"capability\":\"interop.echo\"}");
                if (!response.contains("malformed-request")) throw new AssertionError(response);
                checks++;
            }
            if (checks != 4) throw new AssertionError("missing encoding cases");
        } finally { runtime.stop(); }
        if (!runtime.request("{\"op\":\"runtime.ping\"}").contains("not-started"))
            throw new AssertionError("request after shutdown");
        if (!"process-restart-required".equals(runtime.start(args[0])))
            throw new AssertionError("same-process reboot");
        System.out.println("ACTOR_CLIENT_CHECKS\t6");
    }
}
