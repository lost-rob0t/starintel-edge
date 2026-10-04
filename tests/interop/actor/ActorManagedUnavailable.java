import actor.starintel.edge.StarIntelEdgeRuntime;

/** Actual production Kotlin/JNI must decline unsafe embedding before native boot. */
public final class ActorManagedUnavailable {
    private static int checks;
    private static void check(boolean yes) { checks++; if (!yes) throw new AssertionError("managed gate " + checks); }
    public static void main(String[] args) {
        System.load(args[0]);
        String gate = ActorEmbeddingProbe.gate();
        check(gate.startsWith("passed:"));
        StarIntelEdgeRuntime runtime = StarIntelEdgeRuntime.INSTANCE;
        check(runtime.abiVersion() == 1);
        check("runtime-directory-required".equals(runtime.start(null)));
        check("invalid-runtime-directory".equals(runtime.start("x\u0000y")));
        check("jvm-runtime-embedding-unverified".equals(runtime.start(args[1])));
        check("jvm-runtime-embedding-unverified".equals(runtime.start(args[1])));
        check(runtime.request("{\"op\":\"runtime.ping\"}").contains("not-started"));
        runtime.stop();
        check(runtime.request("{\"op\":\"runtime.ping\"}").contains("not-started"));
        // A second snapshot also confirms the real production JNI did not boot ECL.
        check(ActorEmbeddingProbe.gate().startsWith("passed:"));
        System.out.println("ACTOR_MANAGED_GATE\t" + gate + ";production-jni:" + checks);
    }
}
