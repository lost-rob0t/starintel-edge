/*
 * Closed C ABI adapter for the embedded Android ECL runtime.
 *
 * One process owns one ECL runtime. The surface is intentionally tiny:
 * starintel_ecl_abi_version, starintel_ecl_start[_managed], starintel_ecl_request,
 * starintel_ecl_free and starintel_ecl_stop. Requests are bounded JSON
 * envelopes {"op":string,"payload":string,"capability":string}; only the
 * fixed Lisp dispatcher STAR.EDGE.ANDROID:HANDLE-REQUEST is called and
 * request data is never read, evaluated or turned into Lisp forms.
 */

#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

#include "starintel_ecl_adapter.h"
#include "starintel_ecl_envelope.h"

#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <limits.h>

#include <ecl/ecl.h>
#include <ecl/impl/math_fenv.h>

#ifdef __ANDROID__
#include <android/log.h>
extern void init_lib_CMP(cl_object);
extern void init_lib_ASDF(cl_object);
#endif

#ifndef ECL_UNICODE
#error "The Android UTF-8 adapter requires ECL configured with Unicode support"
#endif

static pthread_mutex_t starintel_ecl_lock = PTHREAD_MUTEX_INITIALIZER;
static int starintel_ecl_started = 0;
/* ECL reboot after cl_shutdown is unproven; only a new owned process may boot again. */
static int starintel_ecl_booted_once = 0;
static cl_object starintel_ecl_dispatch_symbol = OBJNULL;

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

/* ECL base strings are byte-valued characters, not UTF-8. Allocate real
 * character strings and retain the parsed byte length, including U+0000. */
static cl_object lisp_string_from_utf8(const char *bytes, size_t len)
{
    size_t count, cursor = 0, index = 0;
    uint32_t cp;
    cl_object string;
    if (!starintel_utf8_count(bytes, len, &count))
        return OBJNULL;
    string = ecl_alloc_simple_extended_string((cl_index)count);
    while (cursor < len) {
        if (!starintel_utf8_next(bytes, len, &cursor, &cp))
            return OBJNULL;
        ecl_char_set(string, (cl_index)index++, (ecl_character)cp);
    }
    return string;
}

static cl_object lisp_string_or_nil(const struct starintel_string *s)
{
    return s->data ? lisp_string_from_utf8(s->data, s->len) : Cnil;
}

static char *utf8_response(cl_object value)
{
    size_t len = 0, offset = 0;
    cl_index i, count;
    char *result;
    if (value == OBJNULL || !ECL_STRINGP(value))
        return starintel_error_json("invalid-response");
    count = (cl_index)ecl_length(value);
    if (count > STARINTEL_ECL_MAX_RESPONSE_BYTES)
        return starintel_error_json("response-too-large");
    for (i = 0; i < count; i++) {
        uint32_t cp = (uint32_t)ecl_char(value, i);
        size_t width = starintel_utf8_width(cp);
        /* A JSON response must escape every C0 control except JSON whitespace.
         * In particular ABI 1 cannot carry a literal NUL. Never truncate it. */
        if (!width || (cp < 0x20u && cp != '\t' && cp != '\n' && cp != '\r'))
            return starintel_error_json("invalid-response");
        if (width > STARINTEL_ECL_MAX_RESPONSE_BYTES - len)
            return starintel_error_json("response-too-large");
        len += width;
    }
    result = malloc(len + 1);
    if (!result)
        return starintel_error_json("allocation-failed");
    for (i = 0; i < count; i++) {
        uint32_t cp = (uint32_t)ecl_char(value, i);
        size_t width = starintel_utf8_width(cp);
        /* The dispatcher owns its returned JSON string. Still do not overrun
         * the sized allocation if trusted Lisp code unexpectedly mutates it. */
        if (!width || width > len - offset ||
            (cp < 0x20u && cp != '\t' && cp != '\n' && cp != '\r')) {
            free(result);
            return starintel_error_json("invalid-response");
        }
        offset += starintel_utf8_encode(cp, result + offset);
    }
    result[offset] = '\0';
    return result;
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

/* Fixed trusted lifecycle hook only: never names/arguments from request data. */
static void stop_lisp_runtime(void)
{
    cl_object stop = find_lisp_symbol("STAR.EDGE.ANDROID", "STOP-SERVICE-RUNTIME");
    if (stop != OBJNULL)
        (void)si_safe_eval(3, cl_list(1, stop), Cnil, OBJNULL);
}

/* A JVM shares process signals with ECL, but ECL handlers and atexit shutdown
 * require an imported ECL thread. Host tests reproduced hangs on foreign JVM
 * threads even with supported libjsig chaining. Neither host nor ART safe
 * coexistence is established. Fail before cl_boot, without changing handlers,
 * registering atexit, importing threads or claiming an available runtime.
 */
static const char *managed_embedding_requirement(void)
{
#ifdef __ANDROID__
    return "android-runtime-embedding-unverified";
#else
    return "jvm-runtime-embedding-unverified";
#endif
}

static int starintel_ecl_start_impl(const char *runtime_directory, char **error,
                                    int managed)
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
    {
        size_t count;
        size_t length = starintel_bounded_strlen(runtime_directory,
                            STARINTEL_ECL_MAX_DIRECTORY_BYTES + 1u);
        if (length > STARINTEL_ECL_MAX_DIRECTORY_BYTES ||
            !starintel_utf8_count(runtime_directory, length, &count)) {
            if (error) *error = starintel_error("invalid-runtime-directory");
            return -1;
        }
    }
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
    if (starintel_ecl_booted_once) {
        pthread_mutex_unlock(&starintel_ecl_lock);
        if (error)
            *error = starintel_error("process-restart-required");
        return -1;
    }
    if (managed) {
        const char *requirement = managed_embedding_requirement();
        if (requirement) {
            pthread_mutex_unlock(&starintel_ecl_lock);
            if (error) *error = starintel_error(requirement);
            return -1;
        }
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
        starintel_ecl_booted_once = 1;
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
        path = lisp_string_from_utf8(startup_path, strlen(startup_path));
        free(startup_path);
        form = path == OBJNULL ? OBJNULL : load_runtime_assets(path);
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
    if (starintel_ecl_dispatch_symbol == OBJNULL)
        failed = 1;
    if (failed) {
        stop_lisp_runtime();
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

static char *starintel_ecl_request_impl(const char *request_json)
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
    size_t len = starintel_bounded_strlen(request_json,
                                         STARINTEL_ECL_MAX_REQUEST_BYTES + 1u);
    if (len == 0 || len > STARINTEL_ECL_MAX_REQUEST_BYTES) {
        result = starintel_error_json("request-too-large");
        goto out;
    }
    if (!parse_envelope(request_json, len, &env)) {
        result = starintel_error_json("malformed-request");
        goto out;
    }
    {
        cl_object op = lisp_string_or_nil(&env.op);
        cl_object payload = lisp_string_or_nil(&env.payload);
        cl_object capability = lisp_string_or_nil(&env.capability);
        if (op == OBJNULL || payload == OBJNULL || capability == OBJNULL) {
            result = starintel_error_json("malformed-request");
        } else {
            cl_object call = cl_list(4, starintel_ecl_dispatch_symbol,
                                     op, payload, capability);
            cl_object value = si_safe_eval(3, call, Cnil, OBJNULL);
            result = utf8_response(value);
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

static void starintel_ecl_stop_impl(void)
{
    pthread_mutex_lock(&starintel_ecl_lock);
    if (starintel_ecl_started) {
        starintel_ecl_started = 0;
        stop_lisp_runtime();
        starintel_ecl_dispatch_symbol = OBJNULL;
        cl_shutdown();
    }
    pthread_mutex_unlock(&starintel_ecl_lock);
}

/* ECL changes the owning thread's floating-point traps at boot and while Lisp
 * executes. Every public transition must restore the caller's complete fenv,
 * including failed boot, parse/dispatch errors and shutdown. Keep returns in
 * the implementation functions so no early return can skip the END cleanup.
 * This preserves Lisp traps inside the boundary; it does not disable them.
 * The documented same-owning-thread requirement still applies.
 */
int starintel_ecl_start(const char *runtime_directory, char **error)
{
    int status;
    ECL_WITH_LISP_FPE_BEGIN {
        status = starintel_ecl_start_impl(runtime_directory, error, 0);
    } ECL_WITH_LISP_FPE_END;
    return status;
}

int starintel_ecl_start_managed(const char *runtime_directory, char **error)
{
    int status;
    ECL_WITH_LISP_FPE_BEGIN {
        status = starintel_ecl_start_impl(runtime_directory, error, 1);
    } ECL_WITH_LISP_FPE_END;
    return status;
}

char *starintel_ecl_request(const char *request_json)
{
    char *result;
    ECL_WITH_LISP_FPE_BEGIN {
        result = starintel_ecl_request_impl(request_json);
    } ECL_WITH_LISP_FPE_END;
    return result;
}

void starintel_ecl_stop(void)
{
    ECL_WITH_LISP_FPE_BEGIN {
        starintel_ecl_stop_impl();
    } ECL_WITH_LISP_FPE_END;
}
