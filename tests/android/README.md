# Android adapter host regressions

Run the host-JVM lifecycle/init checks, source invariants, and C-parser tests:

```sh
tools/test_android_host.sh
```

This requires an existing JDK with `jdk.compiler`, Python 3, and a C99 compiler
(`CC`, default `cc`). It does not download dependencies.

## Envelope parser ownership

```sh
python3 -m unittest discover -s tests/android -p 'test_envelope_parser.py' -v
PARSER_TEST_CFLAGS='-g -O1 -fsanitize=address,undefined -fno-omit-frame-pointer' \
  ASAN_OPTIONS=detect_leaks=1:halt_on_error=1 UBSAN_OPTIONS=halt_on_error=1 \
  python3 -m unittest discover -s tests/android -p 'test_envelope_parser.py' -v
```

The standalone harness compiles the same private parser header used by the
production adapter. It tracks actual heap allocations, injects allocation
failures at each key/value allocation point, repeats malformed requests,
checks that failed parses leave zero owned allocations and cleared fields,
and calls cleanup twice to catch double-free regressions. A valid parse after
each failure batch verifies ownership transfer and continued usability.

This test does not load or stub ECL. It cannot establish JNI, Android ART,
service, or device support. LeakSanitizer may be unavailable under ptrace-based
sandboxes. If so, report that limitation; a separate run with `detect_leaks=0`
can still exercise AddressSanitizer and UndefinedBehaviorSanitizer. Explicit
allocation-accounting checks remain active in both runs.

## Full native adapter gate

```sh
tests/android/build_host_tests.sh
```

This requires real host ECL and `ecl-config`. Its repeated malformed-envelope
cases cover the public request ABI. Passing the standalone parser test does
not replace this gate or the separate Android/device acceptance gates.

## Common Lisp rollback regression

```sh
sbcl --script tests/runtime.lisp
```

Use the existing ASDF/Sento/Bordeaux Threads dependencies. The lifecycle cases
start several components, fail a later start, assert reverse cleanup order,
repeat failed startups, reject duplicate teardown, and verify cleanup continues
when a stop callback fails. No alternate supervisor or fake Lisp runtime is used.

## Unicode boundary layers

The normal host runner also exhaustively checks the shared scalar codec. If an
existing JDK has JNI headers, it compiles the production JNI wrapper with a
**test-only C ABI substitute**, then runs OpenJDK with `-Xcheck:jni`. It never
substitutes that result for ECL or Android. Missing JNI headers produce an explicit
skip. `JNI_INCLUDE_DIR` can point to already available JNI headers; the runner
never downloads headers, tools or dependencies.

```sh
JNI_INCLUDE_DIR=/path/to/existing/jdk/include tools/test_android_host.sh
sbcl --script tests/runtime.lisp
```

The Lisp runtime gate now loads `tests/android/unicode-runtime.lisp` to cover all
C0 JSON escapes and real closed-dispatch operation/capability NUL-suffix denial.
The standalone C parser tracks decoded byte lengths, including embedded NUL.

The real native shell gate (also used by Nix `host-adapter-test`) runs
`native_unicode_test` in a **separate process** with trusted test-only inspection
operations. It uses real ECL and the production adapter, loads from a non-ASCII
runtime directory, and inspects scalar values and lengths. No test operation is
added to the production Lisp dispatcher or packaged startup assets. See
[the acceptance matrix](../../docs/ANDROID-NATIVE-ACCEPTANCE.md) for executed versus
pending checks and the remaining Kotlin/JNI/ECL/ART requirements.

## Exact packaged source bootstrap on host ECL

```sh
bash tests/android/build_packaged_host_test.sh /path/to/bundle/assets/starintel-edge
```

Requires existing host ECL/ecl-config, a C compiler and Python 3. Pass a built
bundle explicitly. The test copies only its Lisp assets, leaving target ECL
binary modules out of the host process. It hashes all startup/runtime/vendor
files, adds synthetic private init/component marker code only to the copied
init, boots the actual packaged `load-source-op` startup, exercises real actor
routing and confirmed managed stop, and checks byte preservation afterward.
It records logs/hashes in a fresh build directory. The host-compiled adapter
sources must correspond to the bundle under review; record both revisions.
This establishes neither Android binary/ART behavior nor syscall-level absence
of compiler execution. Keep those remaining acceptance requirements explicit.
