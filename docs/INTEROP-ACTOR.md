# Real actor language-boundary integration

> Repaired-source safety status (2026-10-04): managed Java/Kotlin/JNI startup is
> deliberately unavailable before ECL boot. The earlier functional response
> counts below are historical evidence for the prior native source, not current
> managed readiness. Use `actor_embedding.py` for fenv and fail-closed gate
> regressions; full actor mode must remain non-green while managed boot is blocked.
> Standalone C/ECL evidence is limited to controlled host/owned-thread conditions.
> See [embedding safety](EMBEDDING-SAFETY.md).


`python3 tests/interop/actor_interop.py --mode full` is a fail-closed host gate for
existing actor bindings. It never installs prerequisites, downloads packages,
opens listeners, starts an emulator, or substitutes a fake native implementation.
A missing compiler/library, failed command, timeout or assertion exits nonzero.
Python `-O` does not disable its checks. All output is generated in a temporary
directory (or `--output-dir`), including command logs and `summary.json`.

## What actually exists

| Boundary | Production source | Gate |
| --- | --- | --- |
| Kotlin → JNI C → C ABI → ECL Common Lisp | `platforms/android/kotlin/actor/starintel/edge/StarIntelEdgeRuntime.kt`, `platforms/android/native/starintel_ecl_jni.c`, `starintel_ecl_adapter.c` | Full mode compiles all three unchanged, loads real ECL, runs real Sento and validates replies back into Kotlin |
| Java → Kotlin singleton → JNI/C/ECL | Java's `AndroidEclBackend` calls `StarIntelEdgeRuntime.INSTANCE` | Full mode compiles a host Java caller against that actual Kotlin singleton; Android `Context`, service and ART execution remain untested |
| C → ECL Common Lisp | `starintel_ecl_adapter.h` / `.c` | Native/full mode compiles a C client against the production adapter and real ECL |
| Common Lisp → local Sento | `runtime/actors.lisp`, `runtime/android.lisp`, `runtime/host.lisp` | Every mode executes the same corpus on SBCL through the production closed dispatcher and a real actor |
| Common Lisp operation/result mesh | `runtime/mesh.lisp`, `runtime/mesh-sento.lisp` | Every mode runs real local actors over the existing explicit synthetic transport; no socket or cryptography evidence |

ECL and SBCL are implementations of Common Lisp, not additional languages.
JNI is a boundary, not an actor language. No native actor client or actor server
is implemented here for Python, JavaScript, TypeScript or Nim. Their document SDK
interoperability is a separate gate and must not be presented as actor bindings.
There is no generic actor server in C, Java or Kotlin for Lisp to initiate arbitrary
calls into. Return-value coverage proves the implemented reply direction only.

## What is exercised

The trusted `tests/interop/actor/startup.lisp` fixture loads the real runtime and
installs a test host port with one capability, `interop.echo`. Its backend uses
real `sento.actor:ask-s`, with a Lisp actor returning the unchanged payload,
Unicode scalar values, length and delivery sequence. The production dispatcher,
JSON encoder, parser, JNI conversion and ABI are not replaced. This test capability
is never installed by production startup or shipped as an application API.

- Exact payload/reply preservation for empty, ASCII, accented, CJK, non-BMP,
  combining-character, quote/backslash/newline and escaped NUL data
- Raw UTF-8 JSON and escaped JSON independently through C, Java and Kotlin
- Lisp-looking payloads remain opaque data, plus alternating/repeated payloads
  and monotonically increasing actor sequence to detect mixed-up synchronous replies
- Real production `runtime.ping`, ABI 1 and `actor.roundtrip` operations
- Unknown/eval operations, missing/unadvertised capability and operation/capability
  NUL suffixes are rejected; denied requests do not increase actor deliveries
- Malformed UTF-8 on the C boundary, unpaired JSON surrogates, duplicate/unknown
  fields and trailing data; Java/Kotlin additionally send literal NUL and malformed
  UTF-16 strings directly to production JNI
- Shutdown request rejection and the process-restart-required lifecycle guard

The native ABI envelope has only `op`, `payload` and `capability`. It has no
correlation field, request ID or per-request version negotiation. The gate checks
that invented `correlation` and `version` fields are rejected instead of silently
accepted. It checks the actual ABI version separately. The C ABI is NUL-terminated;
literal NUL inside a byte buffer cannot be represented safely and is prohibited by
the ABI. Escaped JSON `\u0000` is supported and tested without truncating suffixes.

The separate CL-only mesh test executes the existing baseline and real-actor
suite, then adds concurrent pending requests, exact result matching for every
correlation/authority field, a wrong protocol version, opaque payload bytes
containing NUL/non-BMP UTF-8, denied actor delivery, and ASCII-only metadata
rejection. It uses the existing synthetic transport to avoid opening a network
listener. This does not establish ZeroMQ/CURVE/ZAP, cross-process mesh, Android
ART, watch, ARM or device behavior.

## Running with already installed prerequisites

All modes need Python 3, SBCL, and Sento's pinned source dependencies available to
ASDF. `CL_SOURCE_REGISTRY=/path/to/existing/host-lisp-sources//` supplies the latter.
`SBCL` can name an existing command; `SBCL_HOME` is useful for relocated SBCL.
The runner keeps ASDF caches within its output directory.

```
python3 tests/interop/actor_interop.py --mode lisp
python3 tests/interop/actor_interop.py --mode native
python3 tests/interop/actor_interop.py --mode full --output-dir /tmp/edge-actor-evidence
```

Native/full mode also needs a Unicode, threaded host ECL and a C compiler. Use
`ECL_CONFIG` (default `ecl-config`) or `ECL_PREFIX` pointing at an existing prefix
with `include/` and `lib/`. `ECL_CFLAGS` and `ECL_LIBS` override discovered flags.
`ECLDIR`, `C_INCLUDE_PATH`, `LIBRARY_PATH` and `LD_LIBRARY_PATH` may be needed for
relocated existing libraries. With `ECL_PREFIX`, the trusted fixture also fixes
ECL's compile-time include/library paths so ASDF can compile the real sources.
This does not alter the production dispatcher or native adapter.

Full mode additionally needs an existing JDK, JNI headers, Kotlin compiler,
Kotlin stdlib and LMDB shared library:

```
export KOTLIN_STDLIB=/existing/kotlin/lib/kotlin-stdlib.jar
export LMDB_LIBRARY=/existing/lib/liblmdb.so
export JNI_INCLUDE_DIR=/existing/jdk/include
export KOTLINC=/existing/kotlin/bin/kotlinc
```

`KOTLINC` may be an existing `java -cp ... org.jetbrains.kotlin.cli.jvm.K2JVMCompiler`
command, and `JAVA`/`CC` may select existing tools. Compilation uses
`java com.sun.tools.javac.Main` and host execution uses `-Xcheck:jni`.
The production Kotlin singleton loads real ECL/LMDB/adapter/JNI libraries.

`summary.json` records the selected mode, exact completed paths and response/check
counts, Lisp implementation and Sento/Bordeaux Threads versions, compiler/JVM
versions, production source SHA-256 hashes and the pinned dependency manifest
hash. Reduced `lisp` or `native` modes are useful diagnostics, not a full pass.
Host results never close the separate Android/ART and physical-device gates.

## Optional document-producer bridge

Repeat `--document-corpus LANGUAGE=/path/to/LANGUAGE-valid.ndjson` for outputs
already verified by the document-language matrix. The gate selects the exact
producer-emitted canonical `person` and `message` lines and sends them as opaque
payloads through each selected actor path. Replies must preserve the complete
original string, scalar sequence and byte-equivalent UTF-8 representation. This
bridges real producer output into the implemented actor boundary; it does not
create a Python/JS/TypeScript/Nim actor SDK. Producer corpus hashes are recorded.
Production, test harness and producer hashes are sampled before execution and
must remain identical at completion. Response comparisons preserve JSON types.

## Observed host embedding warning

The 2026-10-04 real ECL 26.5.5 / OpenJDK 21 host run passes the actor payload and
rejection assertions, but `-Xcheck:jni` reports ECL replacement of JVM signal
handlers (SIGSEGV/SIGILL/SIGBUS/SIGFPE) and an MXCSR floating-point-state change.
These diagnostics are retained verbatim in command logs and in each affected
path's `runtime_warnings`. Such a run is `passed_with_runtime_warnings`, meaning
functional communication passed while a clean/safe host embedding gate remains
unestablished. The gate does not suppress the warnings or alter production signal
handling. Android/ART has different runtime integration and still requires its
own execution gate; these host results do not prove it works there.

Actual JNI usage violations (`WARNING in native method` / `FATAL ERROR in native
method`) fail the gate. Known host embedding warnings remain visible rather than
being mislabeled as a clean production pass. Before starting, the runner marks
its summary `running`, so an interrupted rerun cannot leave an old passing summary.
