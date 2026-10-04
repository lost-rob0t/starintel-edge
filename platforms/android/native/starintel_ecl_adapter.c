/*
 * Closed C ABI adapter for the embedded Android ECL runtime.
 *
 * One process owns one ECL runtime. The surface is intentionally tiny:
 * starintel_ecl_abi_version, starintel_ecl_start, starintel_ecl_request,
 * starintel_ecl_free and starintel_ecl_stop. Requests are bounded JSON
 * envelopes {"op":string,"payload":string,"capability":string}; only the
 * fixed Lisp dispatcher STAR.EDGE.ANDROID:HANDLE-REQUEST is called and
 * request data is never read, evaluated or turned into Lisp forms.
 */

#include "starintel_ecl_adapter.h"

#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <limits.h>

#include <ecl/ecl.h>

#ifdef __ANDROID__
#include <android/log.h>
extern void init_lib_CMP(cl_object);
extern void init_lib_ASDF(cl_object);
#endif

#define STARINTEL_ECL_MAX_REQUEST_BYTES (1024u * 1024u)
#define STARINTEL_ECL_MAX_STRING_BYTES STARINTEL_ECL_MAX_REQUEST_BYTES
#define STARINTEL_ECL_MAX_RESPONSE_BYTES (4u * 1024u * 1024u)

static pthread_mutex_t starintel_ecl_lock = PTHREAD_MUTEX_INITIALIZER;
static int starintel_ecl_started = 0;
static cl_object starintel_ecl_dispatch_symbol = OBJNULL;
static cl_object starintel_ecl_shutdown_symbol = OBJNULL;

struct starintel_string {
    char *data; /* malloc'd, NUL-terminated */
    size_t len;
};

struct starintel_envelope {
    struct starintel_string op;
    struct starintel_string payload;
    struct starintel_string capability;
};

static char *starintel_error(const char *reason)
{
    size_t n = strlen(reason) + 1;
    char *out = malloc(n);
    if (out)
        memcpy(out, reason, n);
    return out;
}

static char *starintel_error_json(const char *reason)
{
    const char *head = "{\"status\":\"error\",\"reason\":\"";
    size_t n = strlen(head) + strlen(reason) + 3;
    char *out = malloc(n);
    if (!out)
        return NULL;
    snprintf(out, n, "%s%s\"}", head, reason);
    return out;
}

static void log_startup_error(const char *message)
{
#ifdef __ANDROID__
    __android_log_print(ANDROID_LOG_ERROR, "StarIntelEdgeRuntime", "%s",
                        message);
#else
    fprintf(stderr, "StarIntel Edge runtime startup failed: %s\n", message);
#endif
}

static cl_object load_runtime_assets(cl_object path)
{
    cl_object condition = ecl_make_symbol("STARTUP-CONDITION", "CL-USER");
    cl_object load = cl_list(2, ecl_make_symbol("LOAD", "CL"), path);
    cl_object success = cl_list(3, ecl_make_symbol("PROGN", "CL"), load, Cnil);
    cl_object render = cl_list(2, ecl_make_symbol("PRINC-TO-STRING", "CL"),
                               condition);
    cl_object clause = cl_list(3, ecl_make_symbol("ERROR", "CL"),
                               cl_list(1, condition), render);
    cl_object form = cl_list(3, ecl_make_symbol("HANDLER-CASE", "CL"),
                             success, clause);
    return si_safe_eval(3, form, Cnil, OBJNULL);
}

unsigned int starintel_ecl_abi_version(void)
{
    return STARINTEL_ECL_ABI_VERSION;
}

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
            if (n + 1 >= cap)
                goto fail;
            out[n++] = (char)ch;
            p++;
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
            if (cp < 0x80u) {
                if (n + 1 >= cap) goto fail;
                out[n++] = (char)cp;
            } else if (cp < 0x800u) {
                if (n + 2 >= cap) goto fail;
                out[n++] = (char)(0xC0u | (cp >> 6));
                out[n++] = (char)(0x80u | (cp & 0x3Fu));
            } else if (cp < 0x10000u) {
                if (n + 3 >= cap) goto fail;
                out[n++] = (char)(0xE0u | (cp >> 12));
                out[n++] = (char)(0x80u | ((cp >> 6) & 0x3Fu));
                out[n++] = (char)(0x80u | (cp & 0x3Fu));
            } else {
                if (n + 4 >= cap) goto fail;
                out[n++] = (char)(0xF0u | (cp >> 18));
                out[n++] = (char)(0x80u | ((cp >> 12) & 0x3Fu));
                out[n++] = (char)(0x80u | ((cp >> 6) & 0x3Fu));
                out[n++] = (char)(0x80u | (cp & 0x3Fu));
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
 * no trailing garbage is allowed.
 */
static int parse_envelope(const char *json, size_t len,
                          struct starintel_envelope *env)
{
    const char *p = json, *end = json + len;
    int seen_op = 0;

    memset(env, 0, sizeof *env);
    p = skip_ws(p, end);
    if (p >= end || *p != '{')
        return 0;
    p = skip_ws(p + 1, end);
    if (p < end && *p == '}') {
        p = skip_ws(p + 1, end);
        return p == end; /* "op" still required */
    }
    for (;;) {
        char *key, *value;
        size_t klen, vlen;

        p = skip_ws(p, end);
        key = parse_json_string(&p, end, &klen);
        if (!key)
            return 0;
        p = skip_ws(p, end);
        if (p >= end || *p != ':') {
            free(key);
            return 0;
        }
        p = skip_ws(p + 1, end);
        value = parse_json_string(&p, end, &vlen);
        if (!value) {
            free(key);
            return 0;
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
            return 0;
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
        return 0;
    }
    return p == end && seen_op && env->op.len > 0;
}

static cl_object lisp_string_or_nil(const struct starintel_string *s)
{
    if (!s->data)
        return Cnil;
    return ecl_make_simple_base_string(s->data, (cl_index)s->len);
}

static cl_object find_lisp_symbol(const char *package_name,
                                  const char *symbol_name)
{
    cl_object package = ecl_find_package(package_name);
    cl_object name;
    cl_object symbol;
    int status = 0;

    if (package == Cnil)
        return OBJNULL;
    name = ecl_make_simple_base_string(symbol_name,
                                       (cl_index)strlen(symbol_name));
    symbol = ecl_find_symbol(name, package, &status);
    return status == 0 ? OBJNULL : symbol;
}

int starintel_ecl_start(const char *runtime_directory, char **error)
{
    struct stat st;
    char *ecl_directory;
    char *temporary_directory;
    char *startup_path;
    size_t path_len;
    cl_object path, form;
    char resolved_runtime[PATH_MAX];
    const char *runtime_root;
    int failed = 0;

    if (error)
        *error = NULL;
    if (!runtime_directory || !*runtime_directory)
        goto require_dir;
    if (stat(runtime_directory, &st) != 0 || !S_ISDIR(st.st_mode))
        goto missing_dir;
    runtime_root = realpath(runtime_directory, resolved_runtime)
                       ? resolved_runtime
                       : runtime_directory;

    pthread_mutex_lock(&starintel_ecl_lock);
    if (starintel_ecl_started) {
        pthread_mutex_unlock(&starintel_ecl_lock);
        if (error)
            *error = starintel_error("already-started");
        return -1;
    }
    path_len = strlen(runtime_root) + sizeof "/ecl/";
    ecl_directory = malloc(path_len);
    if (!ecl_directory) {
        pthread_mutex_unlock(&starintel_ecl_lock);
        if (error)
            *error = starintel_error("allocation-failed");
        return -1;
    }
    snprintf(ecl_directory, path_len, "%s/ecl/", runtime_root);
    if (stat(ecl_directory, &st) == 0 && S_ISDIR(st.st_mode))
        (void)setenv("ECLDIR", ecl_directory, 1);
    free(ecl_directory);
    path_len = strlen(runtime_root) + sizeof "/tmp";
    temporary_directory = malloc(path_len);
    if (!temporary_directory) {
        pthread_mutex_unlock(&starintel_ecl_lock);
        if (error)
            *error = starintel_error("allocation-failed");
        return -1;
    }
    snprintf(temporary_directory, path_len, "%s/tmp", runtime_root);
    if ((mkdir(temporary_directory, 0700) == 0 ||
         (stat(temporary_directory, &st) == 0 && S_ISDIR(st.st_mode)))) {
        (void)setenv("TMPDIR", temporary_directory, 1);
        (void)setenv("XDG_CACHE_HOME", temporary_directory, 1);
    }
    free(temporary_directory);
    {
        char *argv0[1];
        argv0[0] = (char *)"starintel-ecl-adapter";
        if (cl_boot(1, argv0) == 0)
            failed = 1;
    }
#ifdef __ANDROID__
    if (!failed) {
        (void)ecl_init_module(NULL, init_lib_CMP);
        (void)ecl_init_module(NULL, init_lib_ASDF);
    }
#endif
    if (!failed) {
        path_len = strlen(runtime_root) + sizeof "/lisp/startup.lisp";
        startup_path = malloc(path_len);
        if (!startup_path) {
            cl_shutdown();
            pthread_mutex_unlock(&starintel_ecl_lock);
            if (error)
                *error = starintel_error("allocation-failed");
            return -1;
        }
        snprintf(startup_path, path_len, "%s/lisp/startup.lisp",
                 runtime_root);
        path = ecl_make_simple_base_string(startup_path,
                                           (cl_index)strlen(startup_path));
        free(startup_path);
        form = load_runtime_assets(path);
        if (form == OBJNULL) {
            log_startup_error("unhandled ECL condition while loading assets");
            failed = 1;
        } else if (ECL_STRINGP(form)) {
            if (ecl_fits_in_base_string(form)) {
                cl_object base = si_copy_to_simple_base_string(form);
                log_startup_error(ecl_base_string_pointer_safe(base));
            } else {
                log_startup_error("non-base-string ECL startup condition");
            }
            failed = 1;
        }
    }
    if (!failed)
        starintel_ecl_dispatch_symbol =
            find_lisp_symbol("STAR.EDGE.ANDROID", "HANDLE-REQUEST");
    if (!failed)
        starintel_ecl_shutdown_symbol =
            find_lisp_symbol("STAR.EDGE.ANDROID", "SHUTDOWN-ADAPTER-HOST");
    if (starintel_ecl_dispatch_symbol == OBJNULL)
        failed = 1;
    if (starintel_ecl_shutdown_symbol == OBJNULL)
        failed = 1;
    if (failed) {
        cl_shutdown();
        pthread_mutex_unlock(&starintel_ecl_lock);
        if (error)
            *error = starintel_error("runtime-assets-unavailable");
        return -1;
    }
    starintel_ecl_started = 1;
    pthread_mutex_unlock(&starintel_ecl_lock);
    return 0;

require_dir:
    if (error)
        *error = starintel_error("runtime-directory-required");
    return -1;
missing_dir:
    if (error)
        *error = starintel_error("runtime-directory-missing");
    return -1;
}

char *starintel_ecl_request(const char *request_json)
{
    struct starintel_envelope env;
    char *result = NULL;

    pthread_mutex_lock(&starintel_ecl_lock);
    if (!request_json) {
        result = starintel_error_json("request-required");
        goto out;
    }
    if (!starintel_ecl_started) {
        result = starintel_error_json("not-started");
        goto out;
    }
    size_t len = strlen(request_json);
    if (len == 0 || len > STARINTEL_ECL_MAX_REQUEST_BYTES) {
        result = starintel_error_json("request-too-large");
        goto out;
    }
    if (!parse_envelope(request_json, len, &env)) {
        result = starintel_error_json("malformed-request");
        goto out;
    }
    {
        cl_object call = cl_list(4, starintel_ecl_dispatch_symbol,
                                 lisp_string_or_nil(&env.op),
                                 lisp_string_or_nil(&env.payload),
                                 lisp_string_or_nil(&env.capability));
        cl_object value = si_safe_eval(3, call, Cnil, OBJNULL);
        if (!ECL_STRINGP(value) || !ecl_fits_in_base_string(value)) {
            result = starintel_error_json("invalid-response");
        } else {
            cl_object base = si_copy_to_simple_base_string(value);
            const char *bytes = ecl_base_string_pointer_safe(base);
            size_t rlen = (size_t)base->base_string.fillp;
            if (rlen > STARINTEL_ECL_MAX_RESPONSE_BYTES) {
                result = starintel_error_json("response-too-large");
            } else {
                result = malloc(rlen + 1);
                if (!result) {
                    result = starintel_error_json("allocation-failed");
                } else {
                    memcpy(result, bytes, rlen);
                    result[rlen] = '\0';
                }
            }
        }
    }
    free_envelope(&env);
out:
    pthread_mutex_unlock(&starintel_ecl_lock);
    return result;
}

void starintel_ecl_free(char *value)
{
    free(value);
}

void starintel_ecl_stop(void)
{
    pthread_mutex_lock(&starintel_ecl_lock);
    if (starintel_ecl_started) {
        if (starintel_ecl_shutdown_symbol != OBJNULL)
            (void)si_safe_eval(3, cl_list(1, starintel_ecl_shutdown_symbol),
                               Cnil, OBJNULL);
        starintel_ecl_started = 0;
        starintel_ecl_dispatch_symbol = OBJNULL;
        starintel_ecl_shutdown_symbol = OBJNULL;
        cl_shutdown();
    }
    pthread_mutex_unlock(&starintel_ecl_lock);
}
