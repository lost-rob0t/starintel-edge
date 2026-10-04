/** Native snapshots are taken before JVM return stubs can repair FP state. */
public final class ActorEmbeddingProbe {
    private static native String measure(boolean failedBoot);
    public static native String gate();
    public static void main(String[] args) {
        System.load(args[0]);
        String result = measure(Boolean.parseBoolean(args[1]));
        if (!result.startsWith("passed:")) throw new AssertionError(result);
        System.out.println("ACTOR_FENV\t" + result);
    }
}
