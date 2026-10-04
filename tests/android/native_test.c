/*
 * Native host tests for the Android ECL adapter ABI: lifecycle, ownership,
 * bounds and error behavior (docs/ANDROID-RUNTIME.md acceptance gate).
 * Usage: native_test <runtime-directory>
 */

#include "starintel_ecl_adapter.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int checks = 0;
static int failures = 0;

static void check(int value, const char *label)
{
    checks++;
    if (!value) {
        failures++;
        fprintf(stderr, "FAIL: %s\n", label);
    }
}

static void dump_error(const char *label, char **error)
{
    if (*error)
        fprintf(stderr, "  [%s] adapter error: %s\n", label, *error);
    else
        fprintf(stderr, "  [%s] adapter error: (none)\n", label);
    starintel_ecl_free(*error);
    *error = NULL;
}

static int json_has(const char *json, const char *needle)
{
    return json && strstr(json, needle) != NULL;
}

/* Every response returned by the adapter is adapter-owned. */
static char *request_expect(const char *request, const char *needle,
                            const char *label)
{
    char *response = starintel_ecl_request(request);
    check(response != NULL, label);
    if (response) {
        check(json_has(response, needle), label);
        if (!json_has(response, needle))
            fprintf(stderr, "  [%s] response: %s\n", label, response);
    }
    return response; /* caller releases with starintel_ecl_free */
}

static char *oversized_request(void)
{
    size_t n = 2u * 1024u * 1024u;
    char *buffer = malloc(n + 32);
    size_t used;
    if (!buffer)
        exit(2);
    used = (size_t)snprintf(buffer, n + 32, "{\"op\":\"status\",\"payload\":\"");
    while (used < n)
        buffer[used++] = 'x';
    memcpy(buffer + used, "\"}", 3);
    return buffer;
}

int main(int argc, char **argv)
{
    char *error = NULL;
    char *response;

    if (argc != 2) {
        fprintf(stderr, "usage: native_test <runtime-directory>\n");
        return 2;
    }

    check(starintel_ecl_abi_version() == 1u, "abi version is 1");

    /* start argument validation: errors carry an adapter-owned string */
    check(starintel_ecl_start(NULL, &error) != 0, "start(NULL) fails");
    check(error != NULL, "start(NULL) sets error");
    starintel_ecl_free(error);
    error = NULL;

    check(starintel_ecl_start("/nonexistent/starintel", &error) != 0,
          "start(missing dir) fails");
    check(error != NULL, "start(missing dir) sets error");
    starintel_ecl_free(error);
    error = NULL;

    /* requests before start fail closed */
    response = starintel_ecl_request(NULL);
    check(response != NULL, "request(NULL) returns error json");
    starintel_ecl_free(response);

    /* start with the shipped test runtime assets */
    {
        int rc = starintel_ecl_start(argv[1], &error);
        if (rc != 0)
            dump_error("start", &error);
        check(rc == 0, "start(fixture) succeeds");
        check(error == NULL, "successful start leaves error unset");
        starintel_ecl_free(error);
        error = NULL;
    }

    check(starintel_ecl_start(argv[1], &error) != 0, "double start fails");
    check(error != NULL && strstr(error, "already-started") != NULL,
          "double start reports already-started");
    starintel_ecl_free(error);
    error = NULL;

    response = starintel_ecl_request(NULL);
    check(response != NULL, "request(NULL) after start");
    starintel_ecl_free(response);

    response = request_expect("not json at all", "malformed-request",
                              "garbage input rejected");
    starintel_ecl_free(response);

    response = request_expect("{\"payload\":\"x\"}", "malformed-request",
                              "missing op rejected");
    starintel_ecl_free(response);

    response = request_expect("{\"op\":\"status\",\"unknown\":1}",
                              "malformed-request", "unknown field rejected");
    starintel_ecl_free(response);

    response = request_expect("{\"op\":\"status\",\"op\":\"stop\"}",
                              "malformed-request", "duplicate op rejected");
    starintel_ecl_free(response);

    response = request_expect("{\"op\":\"status\"} trailing",
                              "malformed-request", "trailing garbage rejected");
    starintel_ecl_free(response);

    /* Run under a leak/address sanitizer when the host ECL gate is available.
     * Each failure happens after one or more fields transfer to the envelope. */
    {
        static const char *malformed[] = {
            "{}",
            "{\"op\":\"\"}",
            "{\"payload\":\"allocated\",\"capability\":\"allocated\"}",
            "{\"op\":\"status\",\"payload\":\"allocated\",\"capability\":\"allocated\"}x",
            "{\"op\":\"status\",\"payload\":\"allocated\",\"capability\":\"allocated\",\"unknown\":\"x\"}",
            "{\"op\":\"status\",\"payload\":\"allocated\",\"capability\":\"allocated\",}"
        };
        size_t round, i;
        for (round = 0; round < 128; round++) {
            for (i = 0; i < sizeof malformed / sizeof malformed[0]; i++) {
                response = request_expect(malformed[i], "malformed-request",
                                          "repeated partial parse failure rejected");
                starintel_ecl_free(response);
            }
        }
    }

    response = request_expect("{\"op\":\"status\"}",
                              "\"status\":\"unavailable\"",
                              "status reflects real runtime state");
    check(json_has(response, "\"reason\":\"runtime-not-attached\""),
          "status reason is runtime-not-attached");
    starintel_ecl_free(response);

    response = request_expect("{\"op\":\"runtime.ping\"}",
                              "\"status\":\"ok\"",
                              "runtime ping succeeds before actor host attachment");
    check(json_has(response, "\"adapter-abi\":1"),
          "runtime ping reports adapter ABI");
    check(json_has(response, "\"platform\":\"android\""),
          "runtime ping reports Android platform");
    starintel_ecl_free(response);

    response = request_expect("{\"op\":\"actor.roundtrip\"}",
                              "\"status\":\"ok\"",
                              "local Sento actor round-trip succeeds");
    check(json_has(response, "\"actor\":\"roundtrip\""),
          "actor round-trip reports the exercised path");
    check(json_has(response, "\"message\":\"android-local\""),
          "actor round-trip returns its local message");
    starintel_ecl_free(response);

    response = request_expect("{\"op\":\"eval\",\"payload\":\"(quit)\"}",
                              "unknown-operation", "eval is not an operation");
    starintel_ecl_free(response);

    {
        char *big = oversized_request();
        response = request_expect(big, "request-too-large",
                                  "oversized request rejected");
        starintel_ecl_free(response);
        free(big);
    }

    response = request_expect(
        "{\"op\":\"status\",\"payload\":\"{\\\"x\\\":\\\"\\u00e9\\\"}\"}",
        "\"status\":\"unavailable\"",
        "escaped payload parsed, payload never evaluated");
    starintel_ecl_free(response);

    response = request_expect("{\"op\":\"dispatch\",\"capability\":\"camera.photo\"}",
                              "\"status\":\"denied\"",
                              "unadvertised capability denied");
    check(json_has(response, "\"reason\":\"capability-not-authorized\""),
          "denial reason is capability-not-authorized");
    starintel_ecl_free(response);

    response = request_expect("{\"op\":\"stop\"}", "\"status\":\"ok\"",
                              "stop reports ok");
    starintel_ecl_free(response);

    starintel_ecl_stop();

    response = request_expect("{\"op\":\"status\"}", "not-started",
                              "request after stop fails closed");
    starintel_ecl_free(response);

    starintel_ecl_stop(); /* idempotent */

    check(starintel_ecl_start(argv[1], &error) != 0,
          "a second native boot requires a fresh process");
    check(error != NULL && strcmp(error, "process-restart-required") == 0,
          "same-process reboot reports a stable error without calling cl_boot");
    starintel_ecl_free(error);
    error = NULL;

    printf("%d/%d adapter host checks passed\n", checks - failures, checks);
    return failures == 0 ? 0 : 1;
}
