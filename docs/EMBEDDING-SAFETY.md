# Managed ECL embedding safety gate (2026-10-04)

## Result and source policy

Controlled standalone C/ECL actor calls and Unicode payload preservation can be
verified on the owning thread. This is not approval for arbitrary C embedding
with unrelated foreign threads: ECL's process-global handlers have thread-local
state requirements that can apply beyond the JVM case.

Production JNI now calls the additive ABI 1 `starintel_ecl_start_managed` entry.
It returns `jvm-runtime-embedding-unverified` on host or
`android-runtime-embedding-unverified` on Android before `cl_boot`. No ECL signal
handler, thread, atexit callback or managed readiness is created by this gate.
The standalone native start entry is not an application workaround for the gate.

Previously published APKs were built before this source guard and are **not
runtime-ready**. This repair includes no new APK build or publication. Host tests
do not establish ART, ARM64, wearables or device behavior.

## What the successful response tests missed

The prior adapter passed exact actor replies through Java/Kotlin/JNI/C/ECL, but
HotSpot diagnostics reported changed signal handlers and floating-point state.
A direct native snapshot, taken before HotSpot could repair anything, measured
MXCSR control bits changing from `0x1f80` to `0x1900` at boot and remaining changed
after requests and shutdown. ECL owned SEGV/BUS/ILL/FPE/PIPE/INT handlers afterward.

OpenJDK 21's checked-JNI MXCSR verifier both warns and restores the expected
register. Thus a checked-JNI functional pass can benefit from diagnostic
self-repair and does not prove unchecked correctness. Its active signal checker
also turns off when libjsig is present; silent output alone cannot prove chaining.
See the primary [MXCSR verifier](https://raw.githubusercontent.com/openjdk/jdk21u/master/src/hotspot/cpu/x86/stubGenerator_x86_64.cpp)
and [signal implementation](https://raw.githubusercontent.com/openjdk/jdk21u/master/src/hotspot/os/posix/signals_posix.cpp).

## Floating-point repair

Every public native start/request/stop transition wraps its implementation in
ECL's documented `ECL_WITH_LISP_FPE_BEGIN/END` guard. Early returns remain inside
the implementation, so success, validation errors, dispatch failures, failed
boot and shutdown cannot skip restoration. Lisp's own floating-point traps are
retained inside the boundary; no trap is disabled to obtain a green result.
The [ECL 26.5.5 embedding manual](https://ecl.common-lisp.dev/static/files/manual/ecl-26.5.5/Embedding-ECL.html)
describes this guard and foreign-thread import/release requirements.

The fenv regression measures state immediately after the C ABI returns, before
any JVM checked return stub. It includes sentinel nondefault rounding and pending
exceptions, a real caught Lisp division-by-zero condition, a Lisp dispatch error,
denial, malformed input, double start, failed boot, stop and restart rejection.
It runs in fresh checked and unchecked JVM processes as a diagnostic of the
standalone C ABI. That diagnostic does not authorize production managed boot.

## Signal coexistence remains blocked

A separate disposable probe tested the documented
[HotSpot libjsig chaining mechanism](https://docs.oracle.com/en/java/javase/21/vm/signal-chaining.html).
Direct libc signal inspection, rather than warning suppression, confirmed JVM
kernel ownership for SEGV/BUS/ILL/FPE/PIPE. The documented
`ECL_OPT_TRAP_SIGINT=0` managed-host policy kept terminal interruption with the
JVM while retaining ECL fault/FPE/thread-interrupt guards. Java compiled null and
arithmetic exceptions, stack overflow, allocation and GC passed concurrently
with Lisp arithmetic-condition and GC checks.

However, two bounded negative tests still failed:

1. SIGPIPE on an unrelated Java-created thread chained into ECL, which reported
   missing ECL thread-local state and hung. The no-ECL control continued normally.
2. With SIGINT owned by HotSpot, the Java shutdown hook ran, then ECL's registered
   `atexit(cl_shutdown)` executed on an unimported JVM thread and hung with the
   same TLS error. The no-ECL control exited normally with status 130.

Each failing child was stopped by its 10-second diagnostic timeout. These are
actual failures, not hypothetical risks. ECL 26.5.5 source locations are
`src/c/process.d:61–66`, `src/c/unixint.d:530–549,572–580`, and
`src/c/main.d:294–312,625`. The exact failing/control logs and probe sources are
retained under `docs/evidence/embedding/`.

The libjsig getter/begin/end symbols and non-null registered signal entries can
distinguish preloaded from late-loaded libjsig, but that is only a necessary
precondition. It does not solve these TLS/lifecycle failures. No tested signal
configuration is enabled by the production patch; managed startup fails closed.

## Bounded next repair

Before permitting managed boot, establish a platform-specific signal ownership
contract that does not invoke ECL handlers on unimported JVM threads, and ensure
all ECL teardown, including abnormal VM exit, occurs on its owned/imported thread.
Rerun foreign-thread SIGPIPE, Java shutdown, Java exception/GC and Lisp
condition/GC cases, checked and unchecked, with no VM guard suppression.
A dedicated standalone ECL process with a bounded typed local transport is the
cleaner isolation alternative; this change does not implement that architecture.
Android requires its own ART/sigchain and lifecycle evidence, not host libjsig
results. Do not add `-Xrs`, `AllowUserSignalHandlers`, broad trap disabling or
blind handler restoration merely to make the tests quiet.

## Reproduction

With the existing toolchain variables described in `INTEROP-ACTOR.md`:

```
python3 -O tests/interop/actor_embedding.py
python3 tests/interop/actor_interop.py --mode native
```

The first writes source-hashed logs/summary into a fresh temporary directory and
checks both raw fenv preservation and actual production Kotlin/JNI refusal before
boot. The second is controlled standalone host evidence. A full actor run must
fail at managed startup until this safety gate is properly cleared.

### Verified repaired-source checks

- Raw fenv diagnostic: checked JVM 30 normal + 16 failed-boot checks; unchecked
  JVM 30 normal + 16 failed-boot checks. No MXCSR warning remains.
- Managed startup: in each VM mode, two 26-check native snapshots verify no ECL
  boot and unchanged signal ownership, plus nine production Kotlin/JNI assertions.
- Existing host suites: 166 Java lifecycle checks, 57 orchestration/asset checks,
  12 Python/C/JNI transport tests, 109 Common Lisp runtime checks, 81 Lisp Unicode
  checks, and 17 Kotlin facade checks pass. Fake-port and transport-stub coverage
  remains labeled separately from real ECL execution.
- Controlled standalone actor gate: 22 SBCL responses plus 32 raw and 32 escaped
  C/ECL responses, four C lifecycle checks, and 135 CL-only synthetic-mesh checks
  pass on the repaired source. This scope excludes managed startup and arbitrary
  foreign-thread C embedding.
