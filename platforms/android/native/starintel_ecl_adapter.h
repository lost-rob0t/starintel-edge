#pragma once

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

#define STARINTEL_ECL_ABI_VERSION 1U
#define STARINTEL_ECL_MAX_REQUEST_BYTES (1024u * 1024u)
#define STARINTEL_ECL_MAX_RESPONSE_BYTES (4u * 1024u * 1024u)
#define STARINTEL_ECL_MAX_DIRECTORY_BYTES 4096u

unsigned int starintel_ecl_abi_version(void);

/*
 * Starts one process-owned ECL runtime rooted at runtime_directory.
 * Returns zero on success. On failure, *error receives an adapter-owned UTF-8
 * string that the caller releases with starintel_ecl_free. Start/request/stop
 * preserve the owning caller thread's floating-point environment on return.
 * Signal coexistence is a separate platform acceptance requirement.
 * runtime_directory is
 * strict standard UTF-8, NUL-terminated, without embedded NUL, at most
 * STARINTEL_ECL_MAX_DIRECTORY_BYTES bytes. Non-Unicode ECL builds are unsupported.
 */
/* Standalone native process entry; managed/JNI hosts must use the entry below. */
int starintel_ecl_start(const char *runtime_directory, char **error);

/* Additive ABI 1 managed-host entry. Currently fails closed before native boot:
 * jvm-runtime-embedding-unverified on host; android-runtime-embedding-unverified
 * on Android. Signal/foreign-thread/shutdown coexistence needs separate proof.
 * Caller owns the returned error exactly as with starintel_ecl_start.
 */
int starintel_ecl_start_managed(const char *runtime_directory, char **error);

/*
 * Executes one bounded request through the closed Lisp operation dispatcher.
 * This interface never accepts a Lisp form, symbol name, pathname, or shell
 * command. ABI 1 input/output are strict standard UTF-8 NUL-terminated JSON,
 * bounded by the constants above; literal embedded NUL is not representable.
 * JSON \u0000 in string values is decoded with an explicit length, preserved
 * as a Lisp character, and escaped on output. Callers must not pass a byte
 * buffer containing a valid JSON prefix followed by a literal NUL and suffix.
 * The returned UTF-8 JSON string must be released with starintel_ecl_free.
 */
char *starintel_ecl_request(const char *request_json);

void starintel_ecl_free(char *value);
void starintel_ecl_stop(void);

#ifdef __cplusplus
}
#endif
