/* Real production C ABI client. Its stdout protocol is test orchestration only. */
#include "starintel_ecl_adapter.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
int main(int argc, char **argv)
{
    char *error = NULL, *line = NULL;
    size_t capacity = 0;
    ssize_t length;
    if (argc != 2) return 2;
    printf("ACTOR_ABI\t%u\n", starintel_ecl_abi_version());
    if (starintel_ecl_start(argv[1], &error)) {
        fprintf(stderr, "real ECL startup failed: %s\n", error ? error : "unknown");
        starintel_ecl_free(error);
        return 1;
    }
    while ((length = getline(&line, &capacity, stdin)) >= 0) {
        if (length && line[length - 1] == '\n') line[--length] = '\0';
        char *response = starintel_ecl_request(line);
        if (!response) { free(line); starintel_ecl_stop(); return 1; }
        printf("ACTOR_RESULT\t%s\n", response);
        starintel_ecl_free(response);
    }
    free(line);
    starintel_ecl_stop();
    char *after = starintel_ecl_request("{\"op\":\"runtime.ping\"}");
    int valid = after && strstr(after, "not-started");
    starintel_ecl_free(after);
    if (!valid) return 1;
    if (!starintel_ecl_start(argv[1], &error) || !error ||
        strcmp(error, "process-restart-required")) return 1;
    starintel_ecl_free(error);
    puts("ACTOR_CLIENT_CHECKS\t2");
    return 0;
}
