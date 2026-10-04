/* Real ECL adapter Unicode gate. Requires a real Unicode ECL and trusted fixture.
 * A pass here is host-native evidence only; Android/ART still need their gate. */
#include "starintel_ecl_adapter.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static unsigned checks, failures;
static void check(int yes, const char *why)
{
    checks++;
    if (!yes) { failures++; fprintf(stderr, "FAIL: %s\n", why); }
}
static void expect(const char *request, const char *needle)
{
    char *response = starintel_ecl_request(request);
    check(response && strstr(response, needle), needle);
    starintel_ecl_free(response);
}
static void equivalent(const char *raw, const char *escaped, const char *codes)
{
    char a[1024], b[1024];
    char *first, *second;
    snprintf(a, sizeof a, "{\"op\":\"test.unicode\",\"payload\":\"%s\"}", raw);
    snprintf(b, sizeof b, "{\"op\":\"test.unicode\",\"payload\":\"%s\"}", escaped);
    first = starintel_ecl_request(a);
    second = starintel_ecl_request(b);
    check(first && second && strcmp(first, second) == 0, "raw and escaped requests yield identical UTF-8 response");
    check(first && strstr(first, codes), "Lisp sees exact Unicode scalar sequence and length");
    check(first && strstr(first, raw), "response encodes standard UTF-8 characters");
    starintel_ecl_free(first);
    starintel_ecl_free(second);
}
int main(int argc, char **argv)
{
    char *error = NULL, *response;
    int started;
    if (argc != 2) return 2;
    /* Invalid directory bytes reject before any native boot. */
    check(starintel_ecl_start("/tmp/\xc0\x80", &error) != 0 && error &&
          strcmp(error, "invalid-runtime-directory") == 0, "invalid UTF-8 path rejected before boot");
    starintel_ecl_free(error);
    error = NULL;
    started = starintel_ecl_start(argv[1], &error);
    if (started) fprintf(stderr, "ECL Unicode fixture start failed: %s\n", error ? error : "(none)");
    check(started == 0, "real Unicode ECL starts from non-ASCII runtime directory");
    starintel_ecl_free(error);
    if (started) return 1;
    equivalent("", "", "\"length\":0,\"codes\":[]");
    equivalent("ASCII", "ASCII", "\"length\":5,\"codes\":[65,83,67,73,73]");
    equivalent("caf\xc3\xa9", "caf\\u00e9", "\"length\":4,\"codes\":[99,97,102,233]");
    equivalent("\xe4\xb8\xad\xe6\x96\x87", "\\u4e2d\\u6587", "\"length\":2,\"codes\":[20013,25991]");
    equivalent("\xf0\x9f\x99\x82\xf0\x9d\x84\x9e", "\\ud83d\\ude42\\ud834\\udd1e", "\"length\":2,\"codes\":[128578,119070]");
    equivalent("e\xcc\x81", "e\\u0301", "\"length\":2,\"codes\":[101,769]");
    expect("{\"op\":\"test.unicode\",\"payload\":\"before\\u0000after\"}",
           "{\"payload\":\"before\\u0000after\",\"length\":12,\"codes\":[98,101,102,111,114,101,0,97,102,116,101,114]}");
    expect("{\"op\":\"runtime.ping\\u0000suffix\"}", "unknown-operation");
    expect("{\"op\":\"service.stop\\u0000suffix\"}", "unknown-operation");
    expect("{\"op\":\"dispatch\",\"capability\":\"power.status\"}", "\"status\":\"ok\"");
    expect("{\"op\":\"dispatch\",\"capability\":\"power.status\\u0000suffix\"}", "capability-not-authorized");
    expect("{\"op\":\"test.unicode\",\"payload\":\"\xc0\x80\"}", "malformed-request");
    expect("{\"op\":\"test.unicode\",\"payload\":\"\xed\xa0\x80\"}", "malformed-request");
    expect("{\"op\":\"test.unicode\",\"payload\":\"\xf4\x90\x80\x80\"}", "malformed-request");
    expect("{\"op\":\"test.unicode\",\"payload\":\"\\ud800\"}", "malformed-request");
    expect("{\"op\":\"test.invalid-response\"}", "invalid-response");
    expect("{\"op\":\"test.error\"}", "invalid-response");
    expect("{\"op\":\"test.non-string\"}", "invalid-response");
    expect("{\"op\":\"test.surrogate-response\"}", "invalid-response");
    expect("{\"op\":\"test.base-response\"}", "\"\xc3\xa9\"");
    {
        unsigned code;
        for (code = 0; code < 32; code++) {
            char request[128], expected[64];
            snprintf(request, sizeof request, "{\"op\":\"test.unicode\",\"payload\":\"\\u%04x\"}", code);
            snprintf(expected, sizeof expected, "\"length\":1,\"codes\":[%u]", code);
            expect(request, expected);
        }
    }
    response = starintel_ecl_request("{\"op\":\"test.response-limit\",\"payload\":\"exact\"}");
    check(response && strlen(response) == STARINTEL_ECL_MAX_RESPONSE_BYTES, "exact response encoded byte bound accepted");
    starintel_ecl_free(response);
    expect("{\"op\":\"test.response-limit\",\"payload\":\"over\"}", "response-too-large");
    starintel_ecl_stop();
    error = NULL;
    check(starintel_ecl_start(argv[1], &error) != 0 && error &&
          strcmp(error, "process-restart-required") == 0, "Unicode tests retain one-boot guard");
    starintel_ecl_free(error);
    printf("%u/%u real host-ECL Unicode checks passed (not Android/ART)\n", checks - failures, checks);
    return failures != 0;
}
