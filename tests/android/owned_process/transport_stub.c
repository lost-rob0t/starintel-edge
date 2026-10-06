/* HOST TEST DOUBLE ONLY. No ECL, JNI, ART or Lisp semantics are exercised. */
#define _GNU_SOURCE
#include "starintel_ecl_adapter.h"
#include <assert.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

static pthread_t owner;
static int owner_set, stop_hang;
static volatile sig_atomic_t pipe_delivered;
static void on_pipe(int ignored) { (void)ignored; pipe_delivered++; }
static void note(const char *event)
{
    if (!owner_set) { owner = pthread_self(); owner_set = 1; }
    assert(pthread_equal(owner, pthread_self()));
    const char *path = getenv("STUB_LOG");
    if (path) {
        FILE *f = fopen(path, "a"); assert(f);
        fprintf(f, "%s %ld\n", event, (long)getpid()); fclose(f);
    }
}
static void delay(const char *key)
{
    const char *value = getenv(key);
    if (value) {
        long ms = strtol(value, NULL, 10);
        struct timespec wait = {ms / 1000, (ms % 1000) * 1000000};
        while (nanosleep(&wait, &wait)) {}
    }
}
static void hang_exit(void) { delay("STUB_EXIT_MS"); }
unsigned int starintel_ecl_abi_version(void)
{
    note("abi");
    return getenv("STUB_WRONG_ABI") ? 2U : STARINTEL_ECL_ABI_VERSION;
}
int starintel_ecl_start(const char *directory, char **error)
{
    struct stat in, out, err;
    int pipes = 0;
    char byte;
    (void)directory; *error = NULL;
    note("start");
    assert(fstat(0, &in) == 0 && S_ISCHR(in.st_mode) && read(0, &byte, 1) == 0);
    assert(fstat(1, &out) == 0 && fstat(2, &err) == 0);
    assert(out.st_dev == err.st_dev && out.st_ino == err.st_ino);
    for (int fd = 3; fd < 64; fd++) {
        if (fstat(fd, &in) == 0 && S_ISFIFO(in.st_mode)) {
            assert(fcntl(fd, F_GETFD) & FD_CLOEXEC); pipes++;
        }
    }
    assert(pipes == 2); note("private-pipes-stdio-isolated");
    struct sigaction action = {0};
    action.sa_handler = on_pipe; sigemptyset(&action.sa_mask);
    assert(sigaction(SIGPIPE, &action, NULL) == 0);
    if (getenv("STUB_IGNORE_TERM")) signal(SIGTERM, SIG_IGN);
    delay("STUB_START_MS");
    if (getenv("STUB_FAIL_START")) { *error = strdup("private-error-must-not-be-framed"); return -1; }
    if (getenv("STUB_EXIT_MS")) atexit(hang_exit);
    if (getenv("STUB_STDERR")) {
        char bytes[8192]; memset(bytes, 'X', sizeof bytes);
        for (int i = 0; i < 256; i++) assert(write(1, bytes, sizeof bytes) == sizeof bytes);
    }
    return 0;
}
int starintel_ecl_start_managed(const char *dir, char **error)
{ (void)dir; (void)error; abort(); }
char *starintel_ecl_request(const char *request)
{
    note("request");
    if (!strcmp(request, "hang")) { note("request-hanging"); for (;;) pause(); }
    if (!strcmp(request, "stop-hang")) { stop_hang = 1; return strdup("ok"); }
    if (!strcmp(request, "oversize")) {
        char *out = malloc(STARINTEL_ECL_MAX_RESPONSE_BYTES + 2u);
        assert(out); memset(out, 'x', STARINTEL_ECL_MAX_RESPONSE_BYTES + 1u);
        out[STARINTEL_ECL_MAX_RESPONSE_BYTES + 1u] = 0; return out;
    }
    if (!strcmp(request, "bad-utf8")) return strdup("\xc0\x80");
    if (!strcmp(request, "empty")) return strdup("");
    if (!strcmp(request, "null")) return NULL;
    if (!strcmp(request, "exit")) _exit(23);
    if (!strcmp(request, "large")) {
        char *out = malloc(STARINTEL_ECL_MAX_RESPONSE_BYTES + 1u); assert(out);
        memset(out, 'x', STARINTEL_ECL_MAX_RESPONSE_BYTES); out[STARINTEL_ECL_MAX_RESPONSE_BYTES] = 0;
        return out;
    }
    return strdup(request);
}
void starintel_ecl_free(char *value) { note("free"); free(value); }
void starintel_ecl_stop(void)
{
    struct sigaction action;
    sigset_t mask;
    note("stop");
    assert(sigaction(SIGPIPE, NULL, &action) == 0 && action.sa_handler == on_pipe);
    assert(pthread_sigmask(SIG_SETMASK, NULL, &mask) == 0 && !sigismember(&mask, SIGPIPE));
    assert(pipe_delivered == 0); note("own-write-sigpipe-preserved-stub-only");
    if (stop_hang) for (;;) pause();
}
