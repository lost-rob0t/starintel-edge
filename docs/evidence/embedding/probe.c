#define _GNU_SOURCE
#include <jni.h>
#include <signal.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <ecl/ecl.h>
static void report(const char *stage) {
    void *libc = dlopen("libc.so.6",RTLD_NOW | RTLD_LOCAL);
    int (*native_sa)(int,const struct sigaction*,struct sigaction*) = dlsym(libc,"sigaction");
    int signals[] = {SIGSEGV,SIGBUS,SIGILL,SIGFPE,SIGPIPE,SIGINT,SIGUSR2,SIGRTMIN+2};
    for (size_t i=0;i<sizeof signals/sizeof signals[0];i++) {
        struct sigaction visible, kernel;
        Dl_info vis={0},real={0};
        if(sigaction(signals[i],NULL,&visible) || native_sa(signals[i],NULL,&kernel)) abort();
        dladdr((void*)visible.sa_sigaction,&vis); dladdr((void*)kernel.sa_sigaction,&real);
        printf("HANDLER %s sig=%d chained=%s kernel=%s flags=0x%x\n",stage,signals[i],vis.dli_fname?vis.dli_fname:"default",real.dli_fname?real.dli_fname:"default",kernel.sa_flags);
    }
    dlclose(libc);fflush(stdout);
}
JNIEXPORT void JNICALL Java_SignalProbe_boot(JNIEnv *env,jclass type) {
    (void)env;(void)type;
    char *args[]={"edge-signal-probe",NULL};
    report("before");
    if(getenv("EDGE_MANAGED_HOST")) ecl_set_option(ECL_OPT_TRAP_SIGINT, 0);
    printf("OPTIONS int=%ld segv=%ld bus=%ld ill=%ld fpe=%ld pipe=%ld thread_interrupt=%ld gc_incremental=%ld\n",
      (long)ecl_get_option(ECL_OPT_TRAP_SIGINT), (long)ecl_get_option(ECL_OPT_TRAP_SIGSEGV),
      (long)ecl_get_option(ECL_OPT_TRAP_SIGBUS), (long)ecl_get_option(ECL_OPT_TRAP_SIGILL),
      (long)ecl_get_option(ECL_OPT_TRAP_SIGFPE), (long)ecl_get_option(ECL_OPT_TRAP_SIGPIPE),
      (long)ecl_get_option(ECL_OPT_TRAP_INTERRUPT_SIGNAL), (long)ecl_get_option(ECL_OPT_INCREMENTAL_GC));
    ECL_WITH_LISP_FPE_BEGIN { cl_boot(1,args); } ECL_WITH_LISP_FPE_END;
    report("booted");
}
JNIEXPORT jint JNICALL Java_SignalProbe_lispCheck(JNIEnv *env,jclass type) {
    (void)env;(void)type;int result=0;
    ECL_WITH_LISP_FPE_BEGIN {
        cl_object form = ecl_read_from_cstring("(progn (dotimes (i 10) (make-list 10000)) (si:gc t) (handler-case (/ 1d0 0d0) (division-by-zero () 123)))");
        cl_object out=si_safe_eval(3,form,ECL_NIL,ECL_NIL);
        if(ECL_FIXNUMP(out)) result=ecl_fixnum(out);
    } ECL_WITH_LISP_FPE_END;
    return result;
}
JNIEXPORT void JNICALL Java_SignalProbe_shutdown(JNIEnv *env,jclass type) {
    (void)env;(void)type;
    ECL_WITH_LISP_FPE_BEGIN { cl_shutdown(); } ECL_WITH_LISP_FPE_END;
    report("shutdown");
}

JNIEXPORT void JNICALL Java_SignalProbe_interruptSelf(JNIEnv *env,jclass type) {
    (void)env;(void)type; raise(SIGINT);
}

JNIEXPORT void JNICALL Java_SignalProbe_pipeSelf(JNIEnv *env,jclass type) {
    (void)env;(void)type; raise(SIGPIPE);
}
