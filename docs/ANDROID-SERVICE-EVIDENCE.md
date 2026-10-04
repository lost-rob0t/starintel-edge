# Android service integration checkpoint

Date: 2026-10-04. Local source, approved cloud-tool setup and debug artifact work.
The user accepted the linked Android SDK license. No remote write/merge, phone
installation, external peer enrollment, release signing, publication or deployment.
Build, host-runtime and actual ART evidence are distinguished below.

## Provenance

- Original local migration base `37c47b24fab8524fd96f5781d8c1ab3b00906bf5`.
- Verified consumed runtime `f801b024965488c21f93c52a1a9fd2aecd224700` provides
  ECL 26.5.5/LMDB/JNI/Sento source. Earlier ABCL-only issue/README assumptions were
  stale for the runtime already consumed by Android products.
- Service foundation commit `e510607`, reconciled with that runtime and the local
  schema migration in `62d26d6`. Original migration worktree is preserved.
- Canonical StarIntel source/hash lock remains release/schema 0.10.1 at StarLang
  `d6ca8780845c4296f64ac8e65aaa9db143842460`; generated artifacts were not edited.
- Full-server boundary inspected at `a04b5b3b6295b95ef4db6b258656475a4e7b1281`.
  No full-server source was copied or deleted. See [portability gaps](ANDROID-SERVER-PORTABILITY.md).

The exact read-only fetch was initially cancelled by approval review, not retried
until the user explicitly approved it, then succeeded on the one authorized retry:
`git fetch --no-tags origin f801b024965488c21f93c52a1a9fd2aecd224700`.
This authorized source retrieval, not dependency installation or publication.

## Executed locally

- 166 host-JVM lifecycle/init assertions: duplicate-start admission, cancellation,
  late result cleanup, stop retry/ownership, one stable thread across repeated
  starts/stops, config preservation, symlink/size rejection.
- 57 host-JVM ECL orchestration/asset tests with fake native ports: ABI/missing-library
  failures, one native boot per process, ping-independent readiness, cancellation cleanup, Lisp-stop-before-native
  stop, failed/throwing managed or native cleanup retaining STOP_FAILED and blocking
  another boot, bounded generated-code extraction, stale-code removal and private state/init
  preservation through interrupted copy and retry.
- Nine manifest/source invariants: non-exported dedicated process, minimal permissions,
  special-use subtype, no automatic runtime restart, exact self-only watchdog target,
  source-owned native thread, one-shot boot guard/fresh-process retirement, immediate
  foreground launch cancellation, correct AGP Kotlin source registration, init
  preservation/loopback default, native module RUNPATH removal and honest UI.
  Combined Python/C/JNI runner has twelve cases (JNI requires explicit existing headers).
- 109 existing Common Lisp host/runtime checks on real SBCL with already present
  Sento source dependencies.
- 21 new real SBCL/Sento service-profile checks: trusted init evaluation, unchanged
  init bytes, managed component start/stop, persistent local actor routing, closed
  dispatcher rejection, restart and redacted init failure.
- 41 real Lisp cleanup/redaction checks capture warning/error/trace output from
  synthetic failed init/start/stop hooks, preserve stage/component IDs without raw
  condition values, prove all cleanup is attempted and inject a real Bordeaux
  timeout condition to verify actor ownership is retained. A real blocked synthetic
  owner thread plus injected startup timeout proves strict rollback includes the
  attempted component, bounded cleanup failure retains ownership, a second start
  is rejected, and cleanup succeeds after the provider is released. Desktop detailed-warning
  default remains unchanged; Android explicitly opts into redaction/strict cleanup.
- 13,661 host-C parser allocation/Unicode checks, including malformed-field/partial-allocation
  cleanup. This is the real shared envelope parser, not an ECL/native ABI run.
- Eight existing scaffold-target metadata checks and canonical offline schema/hash
  verification; whitespace check.
- Optional private mesh composed from `76a70e8`, `6adc0de` and `1da33d6`,
  independently rerun at `f86f214`: 98 core, 141 binding/ZAP/read-only verifier,
  120 managed-owner lifecycle and 115
  Sento/security checks. These counts repeat shared core assertions and must not
  be summed as unique checks. The script opens no sockets, generates no keys and
  installs nothing. See [PRIVATE-MESH-EVIDENCE.md](PRIVATE-MESH-EVIDENCE.md).

The isolated host-JVM test script uses the existing OpenJDK 21 compiler module with Java 17
source/target. This stripped JDK lacks Java 17 `--release` signatures, so it is not
an Android boot-classpath check. Existing Lisp source emits two preexisting forward
variable warnings while compiling actor code; runtime tests pass. Actual Android
compilation separately passed using the prepared full JDK and Android boot classpath.

## Host native acceptance

The changed C adapter passes 1,583 real ECL 26.5.5 host checks and 69 native Unicode
checks. A separate exact-packaged-source host test passes nine lifecycle checks,
verifies 2,072 unchanged Lisp assets and synthetic init preservation. These are
host results; details and limits are in the native acceptance matrix.

## Android build and packaging

Production code through `b1107a15a6d7f201091175d6ea57a034a62a78b9` built with
AGP 9.4.0, Gradle 9.6.0, JDK 21, SDK 36, Build Tools 36.0.0 and NDK 28.2.13676358.
Subsequent commits change tests/evidence and the optional host mesh budget verifier;
that optional transport is not included in the Android bundle. Packaged production
sources remain identical to `b1107a1`.

- Real Kotlin and Java compilation passed, followed by debug AAR/APK assembly.
- Diagnostic lint passed with **16 warnings**, including newer target API,
  backup-rule advisory, icon and localization warnings. It is not warning-free.
- Both arm64-v8a and x86_64 native bundles built. All 20 ELF modules (four `.so`
  plus six `.fas` per ABI) have no build-host RPATH/RUNPATH, resolve dependencies
  to bundled/platform libraries, and have at least 16 KiB LOAD alignment.
- Both final APKs passed debug-signature, manifest, single-ABI, 16 KiB zip-alignment
  and byte-for-byte native/`.fas`/Lisp asset checks against their intended bundles.
- A stale x86 package was caught and rejected: Nix-preserved timestamps let
  downstream Gradle tasks retain old native assets. The final x86 rebuild forced
  all 88 tasks with `--rerun-tasks`, then passed content-hash verification. Use this
  option or clean isolated outputs when changing bundles; audit the actual APK.

Debug artifact SHA-256 values (these are **not device-accepted release artifacts**):

| Artifact | SHA-256 |
| --- | --- |
| `starintel-edge-diagnostic-x86_64-debug-b1107a1.apk` | `f26b1dd30f1b7b69d0e0d45445143225f70c0d0b926e7201a3fe614205753309` |
| `starintel-edge-diagnostic-arm64-v8a-debug-b1107a1.apk` | `39b23fb1cf64c2add6442cf4afd043db39a02e40bd0756bd96acee2de962ce65` |
| `starintel-edge-service-x86_64-debug-b1107a1.aar` | `48313d9d154a461a4f281d7f9435f9bc96113952ef5aaee26f1af36f0879b568` |
| `starintel-edge-service-arm64-v8a-debug-b1107a1.aar` | `c8c412418cb9a6ad405d49a26bc12916de073a443160bdf1078ab37528f30a5e` |

## Remaining Android gates

ART start/stop, dedicated-process/watchdog/IPC behavior, physical devices, Android
private mesh, full server, Android durability and power-loss gates remain distinct.
The first two software emulator attempts exited before boot. A later quiet API 36
run reached `sys.boot_completed=1` after 1,195 seconds, but the verified APK's ADB
install timed out after 120 seconds. Installation was unconfirmed and no app launch
or lifecycle test ran. The emulator segfault during requested shutdown was not a
service crash. An API 30 compatibility fallback is pending separately; it cannot
establish the API 36 foreground-permission gates. The real host mesh attempt was
environment-blocked before authentication/delivery acceptance.
The existing upstream document's 45 native checks/ART result are historical reported
evidence for its earlier source, not results rerun for this change.

The [native/ART acceptance matrix](ANDROID-NATIVE-ACCEPTANCE.md) describes the
Unicode boundary correction and its precisely limited checks: 5,562,423 codec,
37 production-JNI/host-JVM transport checks with a test C ABI, and 81 production
Lisp Unicode/JSON/closed-dispatch checks on SBCL. Actual ECL conversion now passes
its 69 native checks. ART remains pending;
ASCII lifecycle probes are not Android application-payload evidence.

The remaining full-server contract and device requirements are listed in
[ANDROID-SERVER-PORTABILITY.md](ANDROID-SERVER-PORTABILITY.md).


This is meaningful source and host-runtime progress, **not a completed claim that
star-server is running on Android**. The shipped service status distinguishes the
local actor core from the unavailable full server API and Android mesh integration.
