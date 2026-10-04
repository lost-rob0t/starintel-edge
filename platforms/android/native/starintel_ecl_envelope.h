/* Private envelope parser shared with the host-only ownership tests.
 * This header is not part of the public adapter ABI and has no ECL dependency.
 */
#ifndef STARINTEL_ECL_ENVELOPE_H
#define STARINTEL_ECL_ENVELOPE_H

#include "starintel_ecl_adapter.h"
#include "starintel_utf.h"

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#define STARINTEL_ECL_MAX_STRING_BYTES STARINTEL_ECL_MAX_REQUEST_BYTES

struct starintel_string {
    char *data; /* malloc'd; len includes embedded NUL, final terminator is extra */
    size_t len;
};

struct starintel_envelope {
    struct starintel_string op;
    struct starintel_string payload;
    struct starintel_string capability;
};

static const char *skip_ws(const char *p, const char *end)
{
    while (p < end && (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r'))
        p++;
    return p;
}

static int hex_value(char c)
{
    if (c >= '0' && c <= '9')
        return c - '0';
    if (c >= 'a' && c <= 'f')
        return c - 'a' + 10;
    if (c >= 'A' && c <= 'F')
        return c - 'A' + 10;
    return -1;
}

/*
 * Parses one JSON string starting at *pp (at the opening quote). Returns a
 * malloc'd UTF-8 buffer or NULL. Raw control characters and unpaired
 * surrogates are rejected; every escape must be well formed.
 */
static char *parse_json_string(const char **pp, const char *end,
                               size_t *out_len)
{
    const char *p = *pp;
    char *out;
    size_t cap, n = 0;

    if (p >= end || *p != '"')
        return NULL;
    p++;
    /* Every escape consumes at least two input bytes, so the decoded
     * output never exceeds the remaining input length. */
    cap = (size_t)(end - p) + 1;
    if (cap > STARINTEL_ECL_MAX_STRING_BYTES)
        return NULL;
    out = malloc(cap);
    if (!out)
        return NULL;
    while (p < end && *p != '"') {
        unsigned char ch = (unsigned char)*p;
        if (ch < 0x20)
            goto fail;
        if (ch != '\\') {
            size_t width = 0;
            uint32_t cp;
            if (!starintel_utf8_next(p, (size_t)(end - p), &width, &cp) ||
                width >= cap - n)
                goto fail;
            memcpy(out + n, p, width);
            n += width;
            p += width;
            continue;
        }
        if (++p >= end)
            goto fail;
        switch (*p++) {
        case '"':
        case '\\':
        case '/':
            if (n + 1 >= cap)
                goto fail;
            out[n++] = p[-1];
            break;
        case 'b':
            if (n + 1 >= cap) goto fail;
            out[n++] = '\b';
            break;
        case 'f':
            if (n + 1 >= cap) goto fail;
            out[n++] = '\f';
            break;
        case 'n':
            if (n + 1 >= cap) goto fail;
            out[n++] = '\n';
            break;
        case 'r':
            if (n + 1 >= cap) goto fail;
            out[n++] = '\r';
            break;
        case 't':
            if (n + 1 >= cap) goto fail;
            out[n++] = '\t';
            break;
        case 'u': {
            uint32_t cp = 0;
            int i;
            for (i = 0; i < 4; i++) {
                int d;
                if (p >= end)
                    goto fail;
                d = hex_value(*p++);
                if (d < 0)
                    goto fail;
                cp = cp * 16u + (uint32_t)d;
            }
            if (cp >= 0xD800u && cp <= 0xDBFFu) {
                uint32_t lo = 0;
                if (end - p < 6 || p[0] != '\\' || p[1] != 'u')
                    goto fail;
                p += 2;
                for (i = 0; i < 4; i++) {
                    int d;
                    if (p >= end)
                        goto fail;
                    d = hex_value(*p++);
                    if (d < 0)
                        goto fail;
                    lo = lo * 16u + (uint32_t)d;
                }
                if (lo < 0xDC00u || lo > 0xDFFFu)
                    goto fail;
                cp = 0x10000u + ((cp - 0xD800u) << 10) + (lo - 0xDC00u);
            } else if (cp >= 0xDC00u && cp <= 0xDFFFu) {
                goto fail;
            }
            {
                size_t width = starintel_utf8_width(cp);
                if (!width || width >= cap - n) goto fail;
                n += starintel_utf8_encode(cp, out + n);
            }
            break;
        }
        default:
            goto fail;
        }
    }
    if (p >= end || *p != '"')
        goto fail;
    p++;
    out[n] = '\0';
    *out_len = n;
    *pp = p;
    return out;
fail:
    free(out);
    return NULL;
}

static void free_envelope(struct starintel_envelope *env)
{
    free(env->op.data);
    free(env->payload.data);
    free(env->capability.data);
    memset(env, 0, sizeof *env);
}

/*
 * Strict envelope grammar:
 *   { "op": string, "payload"?: string, "capability"?: string }
 * "op" is required; unknown, duplicate or non-string fields are rejected;
 * no trailing garbage is allowed. On failure all temporary and transferred
 * allocations are released, and ENV is cleared for safe caller cleanup.
 * Pass a fresh or already freed envelope; the caller owns successful results.
 */
static int parse_envelope(const char *json, size_t len,
                          struct starintel_envelope *env)
{
    const char *p, *end;
    int seen_op = 0;

    memset(env, 0, sizeof *env);
    if (!json || !len || len > STARINTEL_ECL_MAX_REQUEST_BYTES)
        return 0;
    p = json;
    end = json + len;
    p = skip_ws(p, end);
    if (p >= end || *p != '{')
        goto fail;
    p = skip_ws(p + 1, end);
    if (p < end && *p == '}')
        goto fail; /* "op" is required even in an otherwise valid object. */
    for (;;) {
        char *key, *value;
        size_t klen, vlen;

        p = skip_ws(p, end);
        key = parse_json_string(&p, end, &klen);
        if (!key)
            goto fail;
        p = skip_ws(p, end);
        if (p >= end || *p != ':') {
            free(key);
            goto fail;
        }
        p = skip_ws(p + 1, end);
        value = parse_json_string(&p, end, &vlen);
        if (!value) {
            free(key);
            goto fail;
        }
        if (klen == 2 && memcmp(key, "op", 2) == 0 && !seen_op) {
            env->op.data = value;
            env->op.len = vlen;
            seen_op = 1;
        } else if (klen == 7 && memcmp(key, "payload", 7) == 0 &&
                   !env->payload.data) {
            env->payload.data = value;
            env->payload.len = vlen;
        } else if (klen == 10 && memcmp(key, "capability", 10) == 0 &&
                   !env->capability.data) {
            env->capability.data = value;
            env->capability.len = vlen;
        } else {
            free(key);
            free(value);
            goto fail;
        }
        free(key);
        p = skip_ws(p, end);
        if (p < end && *p == ',') {
            p++;
            continue;
        }
        if (p < end && *p == '}') {
            p = skip_ws(p + 1, end);
            break;
        }
        goto fail;
    }
    if (p == end && seen_op && env->op.len > 0)
        return 1;
fail:
    free_envelope(env);
    return 0;
}

#endif /* STARINTEL_ECL_ENVELOPE_H */
