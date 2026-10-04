#define _GNU_SOURCE
#include <jni.h>
#include <signal.h>
#include <dlfcn.h>
#include <stdio.h>
JNIEXPORT void JNICALL Java_AdmissionProbe_inspect(JNIEnv *env,jclass clazz,jboolean late) {
 (void)env;(void)clazz;
 if(late) {void*p=dlopen("/usr/lib/jvm/java-21-openjdk-amd64/lib/libjsig.so",RTLD_NOW|RTLD_GLOBAL);printf("LATE_LOAD=%p\n",p);}
 struct sigaction *(*getter)(int)=dlsym(RTLD_DEFAULT,"JVM_get_signal_action");
 void *begin=dlsym(RTLD_DEFAULT,"JVM_begin_signal_setting"), *end=dlsym(RTLD_DEFAULT,"JVM_end_signal_setting");
 void *handler=dlsym(RTLD_DEFAULT,"JVM_handle_linux_signal");
 Dl_info vm={0};dladdr(handler,&vm);
 void *libc=dlopen("libc.so.6",RTLD_NOW|RTLD_LOCAL);
 int(*os_sa)(int,const struct sigaction*,struct sigaction*)=dlsym(libc,"sigaction");
 printf("GETTER=%p BEGIN=%p END=%p VM=%s\n",(void*)getter,begin,end,vm.dli_fname?vm.dli_fname:"none");
 int signals[]={SIGSEGV,SIGBUS,SIGILL,SIGFPE,SIGPIPE};
 for(size_t i=0;i<sizeof signals/sizeof signals[0];i++) {
  struct sigaction real;Dl_info owner={0};os_sa(signals[i],NULL,&real);dladdr((void*)real.sa_sigaction,&owner);
  printf("sig=%d registered=%d kernel-vm-base-match=%d flags=0x%x\n",signals[i],getter&&getter(signals[i])!=NULL,owner.dli_fbase==vm.dli_fbase,real.sa_flags);
 }
 dlclose(libc);fflush(stdout);
}
