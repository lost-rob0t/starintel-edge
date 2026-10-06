# Android owned process transport source proposal

This additive experiment targets published StarIntel Edge commit
`4c3d10b31ca34830ef303c23da3679f334ff0fa5`. It supplies a standalone C runner and
Java pipe client. It does not select an Android backend, change service
readiness, remove the mandatory managed-JNI refusal, or alter Lisp semantics.
Host tests use a deliberately labeled C ABI stub, not ECL or Android ART.

## Boundary

The child alone links the existing `libstarintel_ecl_adapter.so`. Its main
thread calls only ABI 1 version/start/request/free/stop. It checks the actual
version before boot. Existing packaged startup and fixed private `init.lisp`
remain authoritative; no extra reader, evaluator, loader or arbitrary native
function is exposed to request data.

Both framing descriptors are privately duplicated with CLOEXEC before boot.
The child redirects fd0 to `/dev/null` and stdout to stderr. Java drains stderr
without collecting or logging trusted-init text. Only the private response
pipe carries a four-byte big-endian length plus strict standard UTF-8 bytes.
Requests are 1..1 MiB, responses are 1..4 MiB, and literal NUL is rejected.
An empty request means native stop; its empty acknowledgement comes after
`starintel_ecl_stop`. A successful Java close also requires actual zero exit.
The initial transport/ABI handshake is not a service-readiness assertion.

The runner masks SIGPIPE only around its own pipe writes, consumes only a newly
generated own-write EPIPE signal, and restores its previous thread mask. It
does not replace ECL fault/protection handlers or relax their traps. Linux
PDEATHSIG is paired with preboot parent-race and pipe-HUP checks; Java launches
from a retained single worker because Linux parent death follows the creating
thread, not merely the Java application process.

One client owns one child. Concurrent request/close calls are rejected. Each
admitted operation has a bounded deadline; queued work rechecks closure and
time before dispatch. Timeout/interruption retires that exact child without
retry/restart. A launch completing after constructor abandonment still
publishes its child for retirement. Successful repeated close is idempotent.

Retirement attempts and actual-exit observation are independent, because even
`Process.destroy()` can block while closing pipe streams. Neither destroy
method is assumed to implement SIGKILL on ART. `awaitRetirement` confirms
observed process exit, not merely bounded caller return or complete stream
cleanup. If termination is ineffective, ownership and the creator thread are
retained while exit remains unconfirmed. Stream cleanup is asynchronous.

## Packaging contract and unproved Android gates

The future Android caller must obtain the native directory from the actual
`ApplicationInfo.nativeLibraryDir`. The public Java factory accepts that
trusted platform path; it does not itself authenticate Android path provenance.
It must contain a platform-extracted executable PIE named
`libstarintel_ecl_runner.so` and same-ABI sibling adapter/ECL dependencies.
The child receives an explicit `LD_LIBRARY_PATH` for those siblings; parent
loader state is untouched. No app-home binary copying/execution flow is added.
APK extraction, linker namespace behavior, ABI provenance, ART process creation
and retirement, and device lifecycle/permission gates still need evidence.

With an existing authorized compiler and already built matching adapter bundle,
`make -f platforms/android/native/Makefile.owned owned-runner CC=... ADAPTER_DIR=...`
is an optional compile recipe only. It does not fetch, install, sign, package,
run on Android, or integrate this client into a service.

## Host evidence

Run `python3 tests/android/test_owned_process.py --build-dir build/owned-host`
with GCC, Python and Java available. The harness builds a host adapter stub
and PIE runner, then runs 13 native-framing tests and 79 Java assertions.
Coverage includes malformed, oversized and truncated frames, strict UTF-8/NUL,
ABI refusal before stub start, main-thread ownership, descriptors, clean EOF,
stop/exit, preboot HUP (including buffered input), Linux creator-parent death,
transient application-thread exit, late launch, deadlines, single admission,
no dispatch after queued expiry, blocked destroy, and owned-child retirement.

The reconstructed environment's Java 21 installation has no usable `ct.sym`
for `--release 17`. The harness uses `-source 17 -target 17` against installed
Java 21 APIs, with only the expected cross-source options warning disabled.
This establishes neither Java 17 API compatibility nor Android API linkage.
All C-stub behavior, including signal observations, is host transport evidence.
No ECL boot, source-loaded Lisp/Sento/CFFI, or ART signal coexistence is proven.
