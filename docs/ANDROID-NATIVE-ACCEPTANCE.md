# Pending native and ART acceptance

The real host-ECL native and Unicode gates now pass. **Android ART Unicode and
lifecycle acceptance remain separate and pending.** Host C/JVM/SBCL checks,
host ECL, and copied packaged Lisp source bootstrap establish different layers.
Approved build-tool preparation does not itself establish an APK/ART/device pass.

## Unicode correction and evidence boundary

ABI 1 remains NUL-terminated standard UTF-8 JSON. JNI now uses explicit UTF-16
lengths and `GetStringChars` / `NewString`, with a shared strict Unicode scalar
codec also used by the parser and ECL adapter. Invalid continuation bytes,
overlong sequences, surrogate encodings, out-of-range scalars and unpaired Java
surrogates reject without replacement decoding. Literal NUL in a Java request or
pathname rejects before the C ABI; a C ABI caller must supply one NUL-terminated
JSON string, never a prefix/NUL/suffix buffer.

JSON-escaped NUL is valid string data: the parser carries its full byte length,
ECL allocates Unicode character strings and sets each scalar, and the production
Lisp JSON encoder escapes all C0 controls. Operation and capability comparisons
therefore see the complete value, including a NUL suffix. Responses use ECL
character access and bounded standard UTF-8 encoding rather than base-string
byte copying. Non-Unicode ECL builds fail compilation explicitly. The adapter
checks `OBJNULL` before ECL's dereferencing string predicate on safe-eval failure.
The fixed dispatcher, one-boot guard, trusted stop hook and parser cleanup remain.

API selection was checked against:

- [Oracle JNI string operations](https://docs.oracle.com/en/java/javase/21/docs/specs/jni/functions.html#string-operations), including the modified UTF-8 distinction.
- ECL 26.5.5 [external.h](https://gitlab.com/embeddable-common-lisp/ecl/-/blob/26.5.5/src/h/external.h) and [string.d](https://gitlab.com/embeddable-common-lisp/ecl/-/blob/26.5.5/src/c/string.d): `ecl_alloc_simple_extended_string`, `ecl_char_set`, `ecl_char`, and `ecl_length`.
- ECL 26.5.5 [object.h](https://gitlab.com/embeddable-common-lisp/ecl/-/blob/26.5.5/src/h/object.h): `OBJNULL` and `ECL_STRINGP`.
- The repository's locked [nixpkgs ECL definition](https://github.com/NixOS/nixpkgs/blob/e94cb152ed51bd6e24eb4a41f1460252beb52cd2/pkgs/development/compilers/ecl/default.nix) selects that release with Unicode enabled for the host.

Executed local regression evidence (2026-10-04):

- 5,562,423 host-C codec checks, including every Unicode scalar through UTF-8 and
  UTF-16, plus malformed encodings. No ECL or Android dependency.
- 13,661 real parser/ownership checks, including raw/escaped equivalence, non-BMP,
  escaped NUL and suffixes, malformed raw UTF-8 and partial-allocation cleanup.
- 37 checks of the **production JNI wrapper on OpenJDK 21 with `-Xcheck:jni`**,
  linked to a clearly test-only C ABI substitute. Includes byte-limit boundaries,
  non-ASCII paths, unpaired surrogates, malformed response bytes and NUL rejection.
  Official OpenJDK JNI header sources were used because the installed JDK lacks
  headers. This does not exercise Kotlin, ECL, Android ART, or the service.
- 81 production Lisp JSON/closed-dispatch checks on SBCL, including all C0 controls
  and operation/capability NUL suffix denial. Loaded by the existing runtime gate.
- Host C parser/codec checks also passed ASan/UBSan with leak detection disabled.
  LeakSanitizer aborts under this environment's ptrace sandbox, so a leak-sanitizer
  pass is **not** claimed; explicit parser allocation accounting remains active.

`tests/android/build_host_tests.sh` (also invoked by Nix `host-adapter-test`)
passed against real ECL 26.5.5: **1,583/1,583 existing native adapter checks and
69/69 Unicode checks**. The Unicode process boots from an actual `café/🙂` path,
inspects ECL scalar values/lengths, handles raw/escaped non-BMP and embedded NUL,
denies operation/capability NUL suffixes, encodes non-ASCII base strings, rejects
malformed input and invalid/error results, enforces encoded response limits and
retains the one-boot guard. The source-confirmed correction is now backed by host
native execution; it still does not establish the Android Kotlin/JNI/ECL path.

### Host fixture versus exact packaged source bootstrap

The ordinary host fixture uses ASDF's normal compile/load ordering. Initial tests
with raw host dependencies exposed `QUEUE-SENTINEL` being defined only in
`:compile-toplevel` before a `#.` reader evaluation. The host fixture now keeps
path setup, ASDF load and adapter installation in separate top-level phases. A
cold embedded compile inside its earlier lexical frame also reported an unbound
`LL`; the split fixture passed, including the cold Unicode process. These are
host-fixture observations, not a claim that Android compiles dependencies.

The Android bundle already patches the queue `eval-when` to include load/execute,
patches other known source-load assumptions and pre-generates cl-unicode tables
at build time. Its startup explicitly uses `load-source-op` and only the bundled
source registry. To test that distinct path, **9/9 additional host-ECL checks**
passed using a copy of the exact x86_64 bundle built from source
`1d06eaf1a22835a15e95a919c0966a50c118ccfe` (bundle basename
`gy8wh5jc51sk57h4c3g02hvpqg6frkkj-starintel-edge-android-runtime-x86_64-0.1.0`).
All **2,072 packaged startup/runtime/vendor Lisp files** were SHA-256 verified
unchanged before and after execution. A synthetic app-private init remained
unchanged and produced the expected init/component-start/component-stop markers.
Service status, real actor roundtrip, confirmed managed stop, native shutdown and
same-process restart denial passed. No compiled Lisp files appeared under the
copied tree. Host ECL modules were used; Android native modules were not loaded.

Run the reproducible copied-assets gate with
`bash tests/android/build_packaged_host_test.sh /path/to/assets/starintel-edge`.
It saves source hashes, lifecycle markers and a log in its fresh test directory.
Syscall tracing was attempted but denied by ptrace restrictions; **zero external
compiler execution is not claimed as syscall-traced evidence**. Source inspection
confirms no ASDF native compile operation is requested by packaged startup; this
does not rule out internal Lisp bytecode compilation. Actual ART remains required.

## Required Unicode matrix

Run a native ECL test and an installed ART instrumentation test on each supported
ABI with CheckJNI enabled. Compare actual payload characters and lengths, not an
unrelated `status` response which discards payload. Use a test-only fixed typed
echo/inspection operation in trusted fixture code; do not expose arbitrary eval
or load in the production dispatcher.

| Synthetic payload | Required assertion |
| --- | --- |
| ASCII and empty string | No regression or extra terminator |
| `café`, CJK text | Raw JSON and equivalent `\u` escapes produce the same Unicode scalar sequence in Lisp and Kotlin |
| U+1F642 and U+1D11E | Raw supplementary characters and escaped surrogate pairs round-trip identically, without CESU-8, replacement characters or truncation |
| `before\u0000after` | Lisp sees the embedded NUL; JSON response escapes it; Kotlin retains the complete suffix and correct length |
| Combining sequence versus precomposed character | Preserve input code points without implicit normalization |
| Mixed ASCII/BMP/non-BMP near request/response limits | Limits count encoded bytes consistently and fail without partial dispatch |
| Lone UTF-16 surrogate, invalid continuation, overlong UTF-8, out-of-range scalar | Reject explicitly before Lisp dispatch; no silent replacement, CheckJNI abort or resource leak |
| Non-ASCII runtime directory | Startup path conversion is correct, or rejects explicitly before boot; never silently loads another path |

Observe both directions across the actual Kotlin object, JNI library and ECL
dispatcher. Host fake-native Java tests cannot cover this. The old native test's
escaped payload accepted by `status` is not a Unicode round-trip witness.

## Required lifecycle matrix

- Build/compile Kotlin, Java, JNI and ECL from the same source and package assets
  with matching hashes. Verify both x86_64 and arm64-v8a, including 16 KiB pages.
- Start from visible UI; confirm foreground notification and local actor readiness
  after trusted `init.lisp`. Preserve init bytes across starts and asset refresh.
- Exercise duplicate Start/Stop, canceled startup and Service recreation with a
  blocked native call. Verify one stable native owner and one ECL boot per process.
- Revoke notification permission/channel between UI precheck and service entry;
  reject the foreground launch immediately while independent cleanup finishes.
- Inject partial component startup, blocked provider, throwing/timeout shutdown;
  retain ownership and truthful failure until confirmed cleanup or owned-process
  retirement. Never create a second owner or kill an arbitrary thread/process.
- Verify normal Stop acknowledgement, private-process exit and fresh-process
  restart; exercise watchdogs and main-UI survival through live status IPC.
- Force-stop, process death, reboot, Doze, offline transitions and thermal/battery
  limits must never silently restart the runtime or imply indefinite survival.
- Test private state recovery and corruption/capacity handling on Android storage.
  Mesh acceptance additionally requires its independent native/auth/resource gates.
