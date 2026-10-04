/* Host-ECL test of exact packaged Lisp assets, not target binaries or ART.
 * The caller copies the APK asset tree, preserves startup/runtime/vendor bytes,
 * supplies a synthetic init.lisp and records their hashes before/after this run.
 * Use strace -f -e trace=process to establish whether any compiler is executed.
 */
#include "starintel_ecl_adapter.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static unsigned checks, failures;
static void check(int yes, const char *label)
{
    checks++;
    if (!yes) { failures++; fprintf(stderr, "FAIL: %s\n", label); }
}
static void request(const char *json, const char *expected)
{
    char *response = starintel_ecl_request(json);
    printf("%s -> %s\n", json, response ? response : "(null)");
    check(response && strstr(response, expected), expected);
    starintel_ecl_free(response);
}
int main(int argc, char **argv)
{
    char *error = NULL;
    int rc;
    if (argc != 2) return 2;
    rc = starintel_ecl_start(argv[1], &error);
    check(rc == 0, "exact packaged source bootstrap succeeds");
    if (rc) fprintf(stderr, "bootstrap failed: %s\n", error ? error : "(null)");
    starintel_ecl_free(error);
    if (rc) return 1;
    request("{\"op\":\"service.status\"}", "\"init\":\"loaded\"");
    request("{\"op\":\"service.status\"}", "\"state\":\"running\"");
    request("{\"op\":\"actor.roundtrip\"}", "\"message\":\"android-local\"");
    request("{\"op\":\"service.status\"}", "\"state\":\"running\"");
    request("{\"op\":\"service.stop\"}", "\"state\":\"stopped\"");
    request("{\"op\":\"service.status\"}", "\"state\":\"stopped\"");
    starintel_ecl_stop();
    request("{\"op\":\"service.status\"}", "not-started");
    error = NULL;
    check(starintel_ecl_start(argv[1], &error) != 0 && error &&
          strcmp(error, "process-restart-required") == 0, "one-boot guard retained");
    starintel_ecl_free(error);
    printf("%u/%u packaged-source host-ECL checks passed (not Android/ART)\n", checks - failures, checks);
    return failures != 0;
}
