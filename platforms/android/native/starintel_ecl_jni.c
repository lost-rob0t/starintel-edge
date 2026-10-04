#include "starintel_ecl_adapter.h"
#include "starintel_utf.h"

#include <jni.h>
#include <stdlib.h>

enum conversion_failure { INVALID_ENCODING, TOO_LARGE, ALLOCATION_FAILED };

/* Java strings are UTF-16. Use explicit lengths and reject malformed surrogate
 * sequences rather than relying on JNI's incompatible modified UTF-8 API. */
static char *java_utf8(JNIEnv *env, jstring value, size_t limit,
                       enum conversion_failure *failure)
{
    jsize length = (*env)->GetStringLength(env, value);
    const jchar *chars;
    size_t cursor = 0, bytes = 0, offset = 0;
    uint32_t cp;
    char *out = NULL;
    *failure = INVALID_ENCODING;
    if ((size_t)length > limit) {
        *failure = TOO_LARGE;
        return NULL;
    }
    chars = (*env)->GetStringChars(env, value, NULL);
    if (!chars) return NULL; /* Preserve any pending JVM exception. */
    while (cursor < (size_t)length) {
        size_t width;
        if (!starintel_utf16_next(chars, (size_t)length, &cursor, &cp) || !cp)
            goto done; /* ABI 1 transports JSON/pathnames without literal NUL. */
        width = starintel_utf8_width(cp);
        if (width > limit - bytes) {
            *failure = TOO_LARGE;
            goto done;
        }
        bytes += width;
    }
    out = malloc(bytes + 1);
    if (!out) {
        *failure = ALLOCATION_FAILED;
        goto done;
    }
    cursor = 0;
    while (cursor < (size_t)length) {
        (void)starintel_utf16_next(chars, (size_t)length, &cursor, &cp);
        offset += starintel_utf8_encode(cp, out + offset);
    }
    out[offset] = '\0';
done:
    (*env)->ReleaseStringChars(env, value, chars);
    return out;
}

static jstring java_string(JNIEnv *env, const char *value, size_t limit)
{
    size_t len = starintel_bounded_strlen(value, limit + 1u);
    size_t cursor = 0, count = 0;
    uint32_t cp;
    jchar *chars;
    jstring result;
    if (len > limit) return NULL;
    /* Number of UTF-16 code units never exceeds the valid UTF-8 byte count. */
    chars = malloc((len + 1u) * sizeof *chars);
    if (!chars) return NULL;
    while (cursor < len) {
        if (!starintel_utf8_next(value, len, &cursor, &cp)) {
            free(chars);
            return NULL;
        }
        count += starintel_utf16_encode(cp, chars + count);
    }
    result = (*env)->NewString(env, chars, (jsize)count);
    free(chars);
    return result;
}

static jstring literal(JNIEnv *env, const char *ascii)
{
    return java_string(env, ascii, 256u);
}

JNIEXPORT jint JNICALL
Java_actor_starintel_edge_StarIntelEdgeRuntime_abiVersion(JNIEnv *env,
                                                          jobject receiver)
{
    (void)env;
    (void)receiver;
    return (jint)starintel_ecl_abi_version();
}

JNIEXPORT jstring JNICALL
Java_actor_starintel_edge_StarIntelEdgeRuntime_start(JNIEnv *env,
                                                     jobject receiver,
                                                     jstring runtime_directory)
{
    char *directory;
    enum conversion_failure failure;
    char *error = NULL;
    jstring result = NULL;
    (void)receiver;
    if (!runtime_directory)
        return literal(env, "runtime-directory-required");
    directory = java_utf8(env, runtime_directory, STARINTEL_ECL_MAX_DIRECTORY_BYTES,
                          &failure);
    if (!directory) {
        if ((*env)->ExceptionCheck(env)) return NULL;
        return literal(env, "invalid-runtime-directory");
    }
    if (starintel_ecl_start_managed(directory, &error) != 0) {
        result = java_string(env, error ? error : "runtime-start-failed", 1024u);
        if (!result && !(*env)->ExceptionCheck(env))
            result = literal(env, "runtime-start-failed");
    }
    starintel_ecl_free(error);
    free(directory);
    return result;
}

JNIEXPORT jstring JNICALL
Java_actor_starintel_edge_StarIntelEdgeRuntime_request(JNIEnv *env,
                                                       jobject receiver,
                                                       jstring request_json)
{
    char *request = NULL, *response;
    enum conversion_failure failure;
    jstring result;
    (void)receiver;
    if (request_json) {
        request = java_utf8(env, request_json, STARINTEL_ECL_MAX_REQUEST_BYTES,
                            &failure);
        if (!request) {
            if ((*env)->ExceptionCheck(env)) return NULL;
            if (failure == TOO_LARGE)
                return literal(env, "{\"status\":\"error\",\"reason\":\"request-too-large\"}");
            if (failure == ALLOCATION_FAILED)
                return literal(env, "{\"status\":\"error\",\"reason\":\"allocation-failed\"}");
            return literal(env, "{\"status\":\"error\",\"reason\":\"malformed-request\"}");
        }
    }
    response = starintel_ecl_request(request);
    free(request);
    result = response ? java_string(env, response, STARINTEL_ECL_MAX_RESPONSE_BYTES) : NULL;
    starintel_ecl_free(response);
    if (!result && !(*env)->ExceptionCheck(env))
        return literal(env, "{\"status\":\"error\",\"reason\":\"invalid-response\"}");
    return result;
}

JNIEXPORT void JNICALL
Java_actor_starintel_edge_StarIntelEdgeRuntime_stop(JNIEnv *env,
                                                    jobject receiver)
{
    (void)env;
    (void)receiver;
    starintel_ecl_stop();
}
