/* Diagnostic-only standalone C ABI call, not production managed/JNI admission.
 * Managed startup deliberately remains unavailable because of independent
 * signal/TLS/atexit failures. No application may use this probe as a bypass.
 * Measure immediately after production C ABI transitions, before HotSpot's
 * checked JNI return stub can repair MXCSR. No VM flag/guard is disabled. */
#define _GNU_SOURCE
#include "starintel_ecl_adapter.h"
#include <jni.h>
#include <fenv.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#if defined(__SSE__)
#include <xmmintrin.h>
#endif

static int checks, failures;
static unsigned int snapshot_mxcsr(void)
{
#if defined(__SSE__)
    return _mm_getcsr();
#else
    return 0;
#endif
}
static void check(int value, const char *why)
{
    checks++;
    if (!value) { failures++; fprintf(stderr, "FENV FAIL: %s\n", why); }
}
struct state { int rounding, exceptions, traps; unsigned int mxcsr; };
static struct state snapshot(void)
{
    struct state state = {fegetround(), fetestexcept(FE_ALL_EXCEPT), fegetexcept(), snapshot_mxcsr()};
    return state;
}
static void unchanged(struct state before, const char *where)
{
    struct state after = snapshot();
    check(before.rounding == after.rounding && before.exceptions == after.exceptions &&
          before.traps == after.traps && before.mxcsr == after.mxcsr, where);
}
static void expect(const char *request, const char *expected)
{
    struct state before = snapshot();
    char *response = starintel_ecl_request(request);
    unchanged(before, "request preserves exact FP controls and pending exceptions");
    check(response && strstr(response, expected), expected);
    starintel_ecl_free(response);
}
JNIEXPORT jstring JNICALL Java_ActorEmbeddingProbe_measure(JNIEnv *env, jclass type, jboolean fail_boot)
{
    fenv_t original;
    struct state before;
    char *error = NULL;
    int started;
    (void)type;
    checks = failures = 0;
    if (fegetenv(&original)) return (*env)->NewStringUTF(env, "capture-failed");
    check(fesetround(FE_DOWNWARD) == 0, "set sentinel rounding mode");
    check(feraiseexcept(FE_INEXACT) == 0, "set sentinel pending FP exception");
    before = snapshot();
    check(starintel_ecl_start(NULL, &error) != 0, "missing directory fails");
    unchanged(before, "pre-boot argument failure restores FP state");
    starintel_ecl_free(error); error = NULL;
    expect("{\"op\":\"runtime.ping\"}", "not-started");
    before = snapshot();
    started = starintel_ecl_start(getenv("EDGE_PROBE_RUNTIME"), &error);
    unchanged(before, "boot (including failure) preserves FP state");
    if (fail_boot) {
        check(started != 0 && error && !strcmp(error, "runtime-assets-unavailable"), "fixture startup failure");
        starintel_ecl_free(error); error = NULL;
        expect("{\"op\":\"runtime.ping\"}", "not-started");
    } else {
        check(started == 0 && !error, "real ECL fixture starts");
        starintel_ecl_free(error); error = NULL;
        if (started == 0) {
            before = snapshot();
            check(starintel_ecl_start(getenv("EDGE_PROBE_RUNTIME"), &error) != 0 && error &&
                  !strcmp(error, "already-started"), "double start fails");
            unchanged(before, "double-start FP state");
            starintel_ecl_free(error); error = NULL;
            expect("{\"op\":\"runtime.ping\"}", "\"status\":\"ok\"");
            expect("{\"op\":\"dispatch\",\"payload\":\"\",\"capability\":\"interop.fpe\"}", "\"fpe\":\"caught\"");
            expect("{\"op\":\"dispatch\",\"payload\":\"\",\"capability\":\"interop.error\"}", "invalid-response");
            expect("{\"op\":\"dispatch\",\"capability\":\"camera.photo\"}", "capability-not-authorized");
            expect("{\"op\":\"eval\"}", "unknown-operation");
            expect("not-json", "malformed-request");
            expect(NULL, "request-required");
        }
    }
    before = snapshot();
    starintel_ecl_stop();
    unchanged(before, "shutdown FP state");
    before = snapshot();
    starintel_ecl_stop();
    unchanged(before, "idempotent shutdown FP state");
    expect("{\"op\":\"runtime.ping\"}", "not-started");
    before = snapshot();
    check(starintel_ecl_start(getenv("EDGE_PROBE_RUNTIME"), &error) != 0 && error &&
          !strcmp(error, "process-restart-required"), "same-process restart fails");
    unchanged(before, "restart guard FP state");
    starintel_ecl_free(error);
    /* Restore test sentinel before interacting with JNI; the probe never relies
     * on -Xcheck:jni's self-repair to hide a failed native preservation check. */
    if (fesetenv(&original)) abort();
    char result[128];
    snprintf(result, sizeof result, "%s:%d", failures ? "failed" : "passed", checks);
    return (*env)->NewStringUTF(env, result);
}

/* Separate safe admission test: this path must never boot ECL in a VM. */
#include <signal.h>
#include <ecl/ecl.h>
JNIEXPORT jstring JNICALL Java_ActorEmbeddingProbe_gate(JNIEnv *env, jclass type)
{
    static const int signals[] = {SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGPIPE, SIGINT};
    struct sigaction before[sizeof signals / sizeof signals[0]], after;
    struct state fp;
    char *error = NULL;
    char result[128];
    (void)type;
    checks = failures = 0;
    check(ecl_get_option(ECL_OPT_BOOTED) == 0, "ECL initially unbooted");
    for (size_t i = 0; i < sizeof signals / sizeof signals[0]; i++) {
        memset(&before[i], 0, sizeof before[i]);
        check(sigaction(signals[i], NULL, &before[i]) == 0, "read VM signal handler");
    }
    for (int attempt = 0; attempt < 2; attempt++) {
        fp = snapshot();
        check(starintel_ecl_start_managed(getenv("EDGE_PROBE_RUNTIME"), &error) != 0 &&
              error && !strcmp(error, "jvm-runtime-embedding-unverified"), "managed start fails closed");
        unchanged(fp, "managed gate FP state");
        starintel_ecl_free(error); error = NULL;
    }
    expect("{\"op\":\"runtime.ping\"}", "not-started");
    starintel_ecl_stop();
    check(ecl_get_option(ECL_OPT_BOOTED) == 0, "gate never boots ECL or registers its shutdown");
    for (size_t i = 0; i < sizeof signals / sizeof signals[0]; i++) {
        memset(&after, 0, sizeof after);
        check(sigaction(signals[i], NULL, &after) == 0, "reread VM signal handler");
        int same = before[i].sa_sigaction == after.sa_sigaction && before[i].sa_flags == after.sa_flags;
        /* sigset_t contains implementation padding; compare actual signal bits,
         * never uninitialized bytes beyond the kernel's supported signal set. */
        for (int signal = 1; signal < NSIG; signal++)
            if (sigismember(&before[i].sa_mask, signal) != sigismember(&after.sa_mask, signal)) same = 0;
        check(same, "managed gate leaves VM signal ownership unchanged");
    }
    snprintf(result, sizeof result, "%s:%d", failures ? "failed" : "passed", checks);
    return (*env)->NewStringUTF(env, result);
}
