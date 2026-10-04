public final class SignalProbe {
    private static native void boot();
    private static native int lispCheck();
    private static native void shutdown();
    private static native void interruptSelf();
    private static native void pipeSelf();
    static volatile int div = 1;
    static volatile Object field = new Object();
    static volatile int sink;
    static int implicitNull(Object x) { return x.hashCode(); }
    static int arithmetic(int x) { return 4567 / x; }
    static int recurse(int n) { return recurse(n+1)+n; }
    static void checkJvm() throws Exception {
        int caught=0;
        for(int i=0;i<10000;i++) { try{sink=implicitNull(null);}catch(NullPointerException e){caught++;} }
        try{sink=arithmetic(0);}catch(ArithmeticException e){caught++;}
        try{sink=recurse(0);}catch(StackOverflowError e){caught++;}
        if(caught!=10002)throw new AssertionError("JVM checks="+caught);
        for(int i=0;i<5;i++){Thread t=new Thread(()->{for(int j=0;j<100000;j++)field=new byte[256];});t.start();System.gc();t.join();}
        System.out.println("JVM_CHECKS_OK");
    }
    public static void main(String[] args) throws Exception {
        System.load(args[0]);
        if(args.length>1) {
            Runtime.getRuntime().addShutdownHook(new Thread(()->System.out.println("SHUTDOWN_HOOK")));
            if(args[1].endsWith("with-ecl")) boot();
            Thread t=new Thread(()->{if(args[1].startsWith("pipe"))pipeSelf();else interruptSelf();System.out.println("SIGNAL_RETURNED");});
            t.start();t.join();Thread.sleep(500);
            System.out.println("JAVA_CONTINUED_AFTER_SIGNAL");return;
        }
        for(int i=0;i<100000;i++) {sink=implicitNull(field);sink=arithmetic(div);}
        checkJvm();boot();checkJvm();
        int lisp=lispCheck();if(lisp!=123)throw new AssertionError("Lisp check="+lisp);
        System.out.println("LISP_FPE_GC_OK");
        java.util.concurrent.atomic.AtomicReference<Throwable> failure=new java.util.concurrent.atomic.AtomicReference<>();
        Thread concurrent=new Thread(()->{try{for(int i=0;i<10;i++)checkJvm();}catch(Throwable e){failure.set(e);}});
        concurrent.start();
        for(int i=0;i<30;i++) if(lispCheck()!=123) throw new AssertionError("concurrent Lisp");
        concurrent.join();if(failure.get()!=null)throw new AssertionError(failure.get());
        System.out.println("CONCURRENT_JVM_LISP_CHECKS_OK");
        shutdown();checkJvm();System.out.println("PROBE_COMPLETE");
    }
}
