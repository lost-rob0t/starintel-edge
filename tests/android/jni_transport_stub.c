/* Test-only C ABI substitute. Links the real JNI and parser, never ECL.
 * No production dispatcher/lifecycle semantics may be inferred from this file. */
#include "starintel_ecl_adapter.h"
#include "starintel_ecl_envelope.h"
#include <stdio.h>

static unsigned calls, starts;
static char *copy(const char *value)
{
    size_t n = strlen(value) + 1;
    char *out = malloc(n);
    if (out) memcpy(out, value, n);
    return out;
}
static int equals(const struct starintel_string *value, const char *expected)
{
    size_t n = strlen(expected);
    return value->data && value->len == n && memcmp(value->data, expected, n) == 0;
}
unsigned int starintel_ecl_abi_version(void) { return STARINTEL_ECL_ABI_VERSION; }
int starintel_ecl_start(const char *directory, char **error)
{
    /* Return the received bytes to Java, allowing an exact pathname assertion. */
    starts++;
    *error = copy(strlen(directory) == STARINTEL_ECL_MAX_DIRECTORY_BYTES ? "directory-limit-ok" : directory);
    return -1;
}
/* Stub tests only transport encoding; this is not managed embedding evidence. */
int starintel_ecl_start_managed(const char *directory, char **error)
{
    return starintel_ecl_start(directory, error);
}
char *starintel_ecl_request(const char *request)
{
    struct starintel_envelope env;
    char *response = NULL;
    if (!request) return copy("request-required");
    if (!parse_envelope(request, strlen(request), &env))
        return copy("malformed-request");
    if (equals(&env.op, "test.calls") || equals(&env.op, "test.starts")) {
        char out[32];
        snprintf(out, sizeof out, "%u", equals(&env.op, "test.calls") ? calls : starts);
        response = copy(out);
    } else {
        calls++;
        if (equals(&env.op, "test.echo")) response = copy(request);
        else if (equals(&env.op, "test.inspect")) {
            size_t offset = 0, count = 0;
            response = malloc(env.payload.len * 9u + 1u);
            if (response) {
                response[0] = '\0';
                while (offset < env.payload.len) {
                    uint32_t cp;
                    if (!starintel_utf8_next(env.payload.data, env.payload.len, &offset, &cp)) abort();
                    count += (size_t)sprintf(response + count, "%08x ", cp);
                }
            }
        } else if (equals(&env.op, "test.invalid-response")) response = copy("\xc0\x80");
        else if (equals(&env.op, "test.large-response")) {
            response = malloc(STARINTEL_ECL_MAX_RESPONSE_BYTES + 2u);
            if (response) {
                memset(response, 'x', STARINTEL_ECL_MAX_RESPONSE_BYTES + 1u);
                response[STARINTEL_ECL_MAX_RESPONSE_BYTES + 1u] = '\0';
            }
        } else if (equals(&env.op, "test.exact-response")) {
            size_t i;
            response = malloc(STARINTEL_ECL_MAX_RESPONSE_BYTES + 1u);
            if (response) {
                for (i = 0; i < STARINTEL_ECL_MAX_RESPONSE_BYTES; i += 4)
                    memcpy(response + i, "\xf0\x9f\x99\x82", 4);
                response[STARINTEL_ECL_MAX_RESPONSE_BYTES] = '\0';
            }
        } else if (equals(&env.op, "dispatch")) {
            response = copy(equals(&env.capability, "power.status") ? "allowed" : "denied");
        } else response = copy("unknown-operation");
    }
    free_envelope(&env);
    return response;
}
void starintel_ecl_free(char *value) { free(value); }
void starintel_ecl_stop(void) { }
