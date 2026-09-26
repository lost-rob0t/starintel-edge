#pragma once

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

#define STARINTEL_ECL_ABI_VERSION 1U

unsigned int starintel_ecl_abi_version(void);

/*
 * Starts one process-owned ECL runtime rooted at runtime_directory.
 * Returns zero on success. On failure, *error receives an adapter-owned UTF-8
 * string that the caller releases with starintel_ecl_free.
 */
int starintel_ecl_start(const char *runtime_directory, char **error);

/*
 * Executes one bounded request through the closed Lisp operation dispatcher.
 * This interface never accepts a Lisp form, symbol name, pathname, or shell
 * command. The returned UTF-8 JSON string must be released by the caller.
 */
char *starintel_ecl_request(const char *request_json);

void starintel_ecl_free(char *value);
void starintel_ecl_stop(void);

#ifdef __cplusplus
}
#endif
