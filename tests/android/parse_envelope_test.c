/* Host-only tests of the production parser and its actual heap ownership.
 * These tests do not exercise or emulate ECL, JNI, ART, or Android lifecycle.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static size_t checks;
static size_t failures;
static void *allocations[16];
static size_t live_allocations;
static size_t allocation_calls;
static size_t fail_allocation_at;

static void check(int condition, const char *label)
{
    checks++;
    if (!condition) {
        failures++;
        fprintf(stderr, "FAIL: %s\n", label);
    }
}

static void *tracked_malloc(size_t size)
{
    size_t i;
    void *ptr;
    allocation_calls++;
    if (fail_allocation_at && allocation_calls == fail_allocation_at)
        return NULL;
    ptr = malloc(size);
    if (!ptr) {
        fprintf(stderr, "unexpected allocation failure\n");
        exit(2);
    }
    for (i = 0; i < sizeof allocations / sizeof allocations[0]; i++) {
        if (!allocations[i]) {
            allocations[i] = ptr;
            live_allocations++;
            return ptr;
        }
    }
    fprintf(stderr, "allocation tracker full (possible parser leak)\n");
    exit(2);
}

static void tracked_free(void *ptr)
{
    size_t i;
    if (!ptr)
        return;
    for (i = 0; i < sizeof allocations / sizeof allocations[0]; i++) {
        if (allocations[i] == ptr) {
            allocations[i] = NULL;
            live_allocations--;
            free(ptr);
            return;
        }
    }
    fprintf(stderr, "double free or unowned allocation\n");
    exit(2);
}

#define malloc tracked_malloc
#define free tracked_free
#include "starintel_ecl_envelope.h"
#undef malloc
#undef free

static int envelope_empty(const struct starintel_envelope *env)
{
    return !env->op.data && !env->op.len &&
           !env->payload.data && !env->payload.len &&
           !env->capability.data && !env->capability.len;
}

static void rejected(const char *json)
{
    struct starintel_envelope env;
    check(!parse_envelope(json, strlen(json), &env), json);
    check(live_allocations == 0, "rejected envelope releases all allocations");
    check(envelope_empty(&env), "rejected envelope is cleared");
    /* Defensive caller cleanup remains safe, repeatedly, on every failure. */
    free_envelope(&env);
    free_envelope(&env);
    check(live_allocations == 0, "repeated failure cleanup is idempotent");
}

static void unicode_envelope_checks(void)
{
    static const char raw[] = "{\"op\":\"status\",\"payload\":\"caf\xc3\xa9 \xe4\xb8\xad\xe6\x96\x87 \xf0\x9f\x99\x82 \xf0\x9d\x84\x9e e\xcc\x81\"}";
    static const char escaped[] = "{\"op\":\"status\",\"payload\":\"caf\\u00e9 \\u4e2d\\u6587 \\ud83d\\ude42 \\ud834\\udd1e e\\u0301\"}";
    static const char nul[] = "{\"op\":\"status\\u0000suffix\",\"payload\":\"before\\u0000after\",\"capability\":\"power.status\\u0000suffix\"}";
    static const char literal_nul[] = "{\"op\":\"status\"}\0suffix";
    struct starintel_envelope a, b;
    check(parse_envelope(raw, sizeof raw - 1, &a), "raw Unicode accepted");
    check(parse_envelope(escaped, sizeof escaped - 1, &b), "escaped Unicode accepted");
    check(a.payload.len == b.payload.len && !memcmp(a.payload.data, b.payload.data, a.payload.len),
          "raw/escaped Unicode byte equivalence including non-BMP and combining marks");
    free_envelope(&a);
    free_envelope(&b);
    check(parse_envelope(nul, sizeof nul - 1, &a), "escaped NUL accepted as data");
    check(a.op.len == 13 && !memcmp(a.op.data, "status\0suffix", 13), "operation suffix after NUL preserved");
    check(a.payload.len == 12 && !memcmp(a.payload.data, "before\0after", 12), "payload suffix after NUL preserved");
    check(a.capability.len == 19 && !memcmp(a.capability.data, "power.status\0suffix", 19), "capability suffix after NUL preserved");
    free_envelope(&a);
    check(!parse_envelope(literal_nul, sizeof literal_nul - 1, &a), "literal NUL plus trailing data rejected with explicit length");
    check(live_allocations == 0 && envelope_empty(&a), "Unicode parse cleanup owns nothing");
    rejected("{\"op\\u0000suffix\":\"status\"}");
    rejected("{\"op\":\"status\",\"payload\":\"\xc0\x80\"}");
    rejected("{\"op\":\"status\",\"payload\":\"\xed\xa0\x80\"}");
    rejected("{\"op\":\"status\",\"payload\":\"\xf4\x90\x80\x80\"}");
    rejected("{\"op\":\"status\",\"payload\":\"\x80\"}");
    rejected("{\"op\":\"status\",\"payload\":\"\xe2\x82\"}");
    rejected("{\"op\":\"status\",\"payload\":\"\\ud800\\u0041\"}");
}

int main(void)
{
    static const char *invalid[] = {
        "", "not json", "{}", "{ } trailing",
        "{\"op\":\"\"}", "{\"payload\":\"allocated\"}",
        "{\"payload\":\"allocated\",\"capability\":\"allocated\"}",
        "{\"op\":\"status\"} trailing", "{\"op\":\"status\"",
        "{\"op\":\"status\",}", "{\"op\":\"status\",",
        "{\"op\":\"status\",bad}",
        "{\"op\":\"status\",\"payload\"}",
        "{\"op\":\"status\",\"payload\":1}",
        "{\"op\":\"status\",\"payload\":\"bad\\q\"}",
        "{\"op\":\"status\",\"payload\":\"bad\\uD800\"}",
        "{\"op\":\"status\",\"payload\":\"bad\\uDC00\"}",
        "{\"op\":\"status\",\"unknown\":\"allocated\"}",
        "{\"op\":\"status\",\"op\":\"duplicate\"}",
        "{\"op\":\"status\",\"payload\":\"one\",\"payload\":\"two\"}",
        "{\"op\":\"status\",\"capability\":\"one\",\"capability\":\"two\"}",
        "{\"op\":\"status\",\"payload\":\"allocated\",\"capability\":\"allocated\"}x",
        "{\"op\":\"status\",\"payload\":\"allocated\",\"capability\":\"allocated\",\"unknown\":\"x\"}",
        "{\"op\":\"status\",\"payload\":\"allocated\",\"capability\":\"allocated\",\"bad\\q\":\"x\"}",
        "{\"op\":\"status\",\"payload\":\"allocated\",\"capability\":\"allocated\",\"bad\"}"
    };
    const char *valid = "{\"op\":\"status\",\"payload\":\"line\\n\\uD83D\\uDE80\",\"capability\":\"\"}";
    struct starintel_envelope env;
    size_t round, i;

    for (round = 0; round < 128; round++) {
        for (i = 0; i < sizeof invalid / sizeof invalid[0]; i++)
            rejected(invalid[i]);
        /* The same parser remains usable after each batch of failures. */
        check(parse_envelope(valid, strlen(valid), &env), "valid envelope accepted after failures");
        check(live_allocations == 3, "successful parse transfers exactly three allocations");
        check(env.op.len == 6 && memcmp(env.op.data, "status", 6) == 0, "op preserved");
        check(env.payload.len == 9 && memcmp(env.payload.data, "line\n\xf0\x9f\x9a\x80", 9) == 0,
              "escaped payload decoded correctly");
        check(env.capability.data && env.capability.len == 0, "empty optional value preserved");
        free_envelope(&env);
        free_envelope(&env);
        check(live_allocations == 0 && envelope_empty(&env), "success cleanup is idempotent");
    }

    /* Fail every key/value allocation point, including after prior ownership
     * transfers. Also cover the temporary value of a rejected unknown field. */
    for (i = 1; i <= 8; i++) {
        allocation_calls = 0;
        fail_allocation_at = i;
        rejected(invalid[22]);
    }
    for (i = 1; i <= 6; i++) {
        allocation_calls = 0;
        fail_allocation_at = i;
        rejected(valid);
    }
    fail_allocation_at = 0;
    unicode_envelope_checks();
    printf("%zu/%zu parser ownership checks passed (host only)\n", checks - failures, checks);
    return failures ? 1 : 0;
}
