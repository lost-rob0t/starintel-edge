package actor.starintel.edge;

/** Host JVM executes the production JNI wrapper with a test-only C transport.
 * This is deliberately not the Kotlin runtime, ECL, Android ART, or an APK. */
public final class StarIntelEdgeRuntime {
    private native int abiVersion();
    private native String start(String directory);
    private native String request(String json);
    private native void stop();
    private static int checks;
    private static void check(boolean yes, String message) {
        checks++;
        if (!yes) throw new AssertionError(message);
    }
    private static String envelope(String op, String payload) {
        return "{\"op\":\"" + op + "\",\"payload\":\"" + payload + "\"}";
    }
    public static void main(String[] args) {
        System.load(args[0]);
        StarIntelEdgeRuntime runtime = new StarIntelEdgeRuntime();
        check(runtime.abiVersion() == 1, "ABI remains 1");
        for (String text : new String[]{"", "ASCII", "café", "中文", "🙂𝄞", "é", "é"}) {
            String json = envelope("test.echo", text);
            check(json.equals(runtime.request(json)), "exact UTF-16 -> UTF-8 -> UTF-16 roundtrip");
        }
        String raw = "café 中文 🙂𝄞 é";
        String escaped = "caf\\u00e9 \\u4e2d\\u6587 \\ud83d\\ude42\\ud834\\udd1e e\\u0301";
        check(runtime.request(envelope("test.inspect", raw)).equals(
              runtime.request(envelope("test.inspect", escaped))), "raw/escaped scalars equivalent");
        check("00000062 00000065 00000066 0000006f 00000072 00000065 00000000 00000061 00000066 00000074 00000065 00000072 ".equals(
              runtime.request(envelope("test.inspect", "before\\u0000after"))), "escaped NUL and suffix reach C parser");
        check(!runtime.request(envelope("test.inspect", "é")).equals(
               runtime.request(envelope("test.inspect", "é"))), "no normalization");
        check(runtime.request(envelope("test.echo\\u0000suffix", "x")).contains("unknown-operation"), "operation suffix not truncated");
        check("allowed".equals(runtime.request("{\"op\":\"dispatch\",\"capability\":\"power.status\"}")), "test capability control");
        check("denied".equals(runtime.request("{\"op\":\"dispatch\",\"capability\":\"power.status\\u0000suffix\"}")), "capability suffix preserved");
        String before = runtime.request("{\"op\":\"test.calls\"}");
        for (String bad : new String[]{String.valueOf((char)0xd800), String.valueOf((char)0xdc00),
                new String(new char[]{0xd800, 'A'}), "prefix" + (char)0 + "suffix"}) {
            check(runtime.request(envelope("test.echo", bad)).contains("malformed-request"), "malformed UTF-16/literal NUL rejected");
            check(runtime.start("/runtime/" + bad).equals("invalid-runtime-directory"), "malformed directory rejected");
        }
        check(runtime.request("{\"op\":\"test.calls\"}").equals(before), "bad JNI input never calls C dispatcher");
        check("/runtime/café/中文/🙂".equals(runtime.start("/runtime/café/中文/🙂")), "pathname uses standard UTF-8");
        check(runtime.request(envelope("test.echo", "\\ud800")).contains("malformed-request"), "unpaired JSON surrogate rejected");
        check(runtime.request(envelope("test.echo", "\\udc00")).contains("malformed-request"), "low JSON surrogate rejected");
        check(runtime.request("{\"op\":\"test.invalid-response\"}").contains("invalid-response"), "malformed C UTF-8 not fed to JVM");
        check(runtime.request("{\"op\":\"test.large-response\"}").contains("invalid-response"), "oversize C response rejected");
        check("🙂".repeat(1024 * 1024).equals(runtime.request("{\"op\":\"test.exact-response\"}")), "exact 4 MiB UTF-8 response accepted");
        check("directory-limit-ok".equals(runtime.start("é".repeat(2048))), "directory exact 4096 encoded bytes accepted");
        String starts = runtime.request("{\"op\":\"test.starts\"}");
        check("invalid-runtime-directory".equals(runtime.start("é".repeat(2048) + "x")), "directory encoded byte limit enforced");
        check(starts.equals(runtime.request("{\"op\":\"test.starts\"}")), "oversize directory never calls C start");
        int available = 1024 * 1024 - envelope("test.echo", "").length();
        String payload = "aé🙂".repeat(available / 7) + "x".repeat(available % 7);
        String exact = envelope("test.echo", payload);
        check(runtime.request(exact).equals(exact), "exact 1 MiB encoded bound accepted");
        before = runtime.request("{\"op\":\"test.calls\"}");
        check(runtime.request(envelope("test.echo", payload + "x")).contains("request-too-large"), "encoded byte bound rejects plus one");
        check(runtime.request("{\"op\":\"test.calls\"}").equals(before), "oversized input never calls C dispatcher");
        check("request-required".equals(runtime.request(null)), "null still reaches C ABI");
        check("runtime-directory-required".equals(runtime.start(null)), "null directory rejected");
        runtime.stop();
        System.out.println(checks + " host-JVM JNI transport checks passed with -Xcheck:jni (test C ABI, no ECL/ART)");
    }
}
