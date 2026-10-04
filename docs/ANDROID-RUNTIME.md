# Android Common Lisp runtime boundary

`starintel-edge` owns the reusable Android runtime artifact. Android products
consume an exact Edge revision and must not carry a second ECL boot layer,
Common Lisp actor registry, Tek9 native adapter, or copy of the runtime
operation dispatcher.

## Repository ownership

| Owner | Responsibility |
| --- | --- |
| `starintel-edge` | ECL and LMDB ABI builds, closed C ABI, trusted Common Lisp runtime, local actor execution, Tek9 adapter, runtime conformance tests |
| Android/Wear products | UI, Android permissions and lifecycle, collection workflows, app-private storage selection, thin Kotlin/JNI binding |
| `starintel-biz` | Private non-secret policy/configuration references and deployment-time secret indirection |
| Canonical StarIntel schema repository | JSON-LD document and relation contract; Edge does not fork or infer schema versions |

Quasar Mobile and product UI are out of scope for this runtime branch. They are
not modified until their owner explicitly approves downstream integration.

## Artifact contract

The flake produces separate `x86_64` emulator and `arm64-v8a` device packages.
The final runtime bundle has this stable layout:

```text
jni/<abi>/libecl.so
jni/<abi>/liblmdb.so
jni/<abi>/libstarintel_ecl_adapter.so
jni/<abi>/libstarintel_ecl_jni.so
include/starintel_ecl_adapter.h
kotlin/actor/starintel/edge/StarIntelEdgeRuntime.kt
assets/starintel-edge/lisp/
manifest.json
```

`android-runtime-diagnostic-apk` is a separate unsigned test artifact. It is
not a product UI and is not a downstream application dependency. It exists to
prove that the packaged libraries and trusted Lisp assets boot inside ART.

The bundle statically registers ECL's CMP and ASDF modules with the embedded
runtime, then source-loads the pinned actor dependency tree. Android therefore
needs neither a shell nor an on-device C toolchain. ECL temporary/cache files
are confined to `<runtime-directory>/tmp`, which the native adapter creates
mode 0700 under app-private storage.

The C ABI version is independent of the StarIntel document release. Consumers
must check `starintel_ecl_abi_version()` before starting the runtime. The only
request entrypoint accepts bounded JSON and dispatches a closed operation name;
there is no eval, arbitrary load, arbitrary symbol invocation, filesystem API,
environment access, or shell access.

Starting the adapter also starts the process-owned managed runtime and Sento
actor system. `actor.list` projects only actors compiled into the trusted Edge
image, and `actor.dispatch` resolves only those registered IDs. An `entrypoint`
string supplied by a client remains inert data: it is never resolved or called.
The base image exposes the infrastructure-only `runtime.echo` actor. Domain
experts remain owned by their canonical expert packages and are unavailable
until included in a trusted image.

## Acceptance gates

| Gate | Status (2026-09-25) |
| --- | --- |
| Native host tests: lifecycle, ownership, bounds, error behavior | Green — `nix build .#checks.x86_64-linux.host-adapter-test` (45/45); ECL boots in-process and exercises the real Sento actor round-trip through the closed dispatcher |
| Both Android ABI packages build from the pinned Nix flake | Green — `android-runtime-x86_64` and `android-runtime-arm64-v8a` build with matched ECL 26.5.5 cross bootstraps, Android API 24 and NDK 28.2.13676358 |
| x86_64 emulator loads the libraries inside ART and answers through the Kotlin/JNI boundary | Green — API 36 `emulator-5584`; UI and logcat report ECL boot, adapter ABI 1 and PASS |
| Actor dispatch exercised locally with networking disabled | Green — Wi-Fi and mobile data disabled; `actor.roundtrip` delivers `android-local` through a real local Sento actor; diagnostic APK declares no Internet permission |
| Managed actor catalog and closed dispatch | Green in host/ART diagnostics for the trusted `runtime.echo` actor; product/domain actors are not fabricated |
| ARM64 build/package gate | Green — complete arm64-v8a runtime bundle cross-built from the same flake |
| Product UI and physical-device claims | Out of scope; separate acceptance evidence required |

The closed surface is `starintel_ecl_abi_version`, `starintel_ecl_start`,
`starintel_ecl_request`, `starintel_ecl_free`, `starintel_ecl_stop`
(`platforms/android/native/starintel_ecl_adapter.h`). Requests are bounded
JSON envelopes `{"op","payload","capability"}`; unknown fields, duplicates,
oversized input and malformed JSON are rejected before any Lisp call. Only
the fixed dispatcher `STAR.EDGE.ANDROID:HANDLE-REQUEST` is called; the host
test fixture loads the real runtime sources relative to its own boot file.

Downstream consumers should pin this repository to an exact revision, consume
the matching ABI package, copy `jni/<abi>` into their native-library packaging,
copy `assets/starintel-edge` unchanged, and compile only the supplied thin
Kotlin binding. Product repositories do not vendor or edit the Lisp runtime.
