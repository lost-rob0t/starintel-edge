#include "starintel_ecl_adapter.h"

#include <jni.h>

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
    const char *directory;
    char *error = NULL;
    jstring result = NULL;

    (void)receiver;
    if (!runtime_directory)
        return (*env)->NewStringUTF(env, "runtime-directory-required");
    directory = (*env)->GetStringUTFChars(env, runtime_directory, NULL);
    if (!directory)
        return NULL;
    if (starintel_ecl_start(directory, &error) != 0) {
        result = (*env)->NewStringUTF(
            env, error ? error : "runtime-start-failed");
    }
    starintel_ecl_free(error);
    (*env)->ReleaseStringUTFChars(env, runtime_directory, directory);
    return result;
}

JNIEXPORT jstring JNICALL
Java_actor_starintel_edge_StarIntelEdgeRuntime_request(JNIEnv *env,
                                                       jobject receiver,
                                                       jstring request_json)
{
    const char *request = NULL;
    char *response;
    jstring result;

    (void)receiver;
    if (request_json) {
        request = (*env)->GetStringUTFChars(env, request_json, NULL);
        if (!request)
            return NULL;
    }
    response = starintel_ecl_request(request);
    if (request_json)
        (*env)->ReleaseStringUTFChars(env, request_json, request);
    result = response ? (*env)->NewStringUTF(env, response) : NULL;
    starintel_ecl_free(response);
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
