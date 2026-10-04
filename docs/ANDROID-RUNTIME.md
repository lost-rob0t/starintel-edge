# Android Common Lisp runtime boundary

> Current safety gate (2026-10-04): managed JVM/ART startup is unavailable before
> ECL boot. Existing published APKs predate this guard and are **not runtime-ready**.
> No replacement APK has been built or published for this repair. See
> [embedding safety evidence](EMBEDDING-SAFETY.md).


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

## Acceptance gates

| Gate | Current interpretation (2026-10-04) |
| --- | --- |
| Standalone native C/ECL | Scoped to controlled host processes and the documented owning thread; arbitrary foreign-thread embedding is not established |
| Host Java/Kotlin/JNI startup | Fails closed with `jvm-runtime-embedding-unverified` before `cl_boot` |
| Android ART startup | Fails closed with `android-runtime-embedding-unverified`; separate signal/thread/shutdown acceptance is required |
| Both Android ABI packages / previous diagnostic APK | Historical packaging evidence only; published APKs predate the guard and are not runtime-ready |
| Actor dispatch and document payload interoperability | Prior functional passes do not establish managed runtime safety; source-hashed evidence must distinguish old and repaired native adapters |
| Physical ARM64/watch/glasses behavior | Not established by these host tests |

The closed surface is `starintel_ecl_abi_version`, `starintel_ecl_start`,
`starintel_ecl_start_managed`, `starintel_ecl_request`, `starintel_ecl_free`, `starintel_ecl_stop`
(`platforms/android/native/starintel_ecl_adapter.h`). Requests are bounded
JSON envelopes `{"op","payload","capability"}`; unknown fields, duplicates,
oversized input and malformed JSON are rejected before any Lisp call. Only
the fixed dispatcher `STAR.EDGE.ANDROID:HANDLE-REQUEST` is called; the host
test fixture loads the real runtime sources relative to its own boot file.

Downstream consumers should pin this repository to an exact revision, consume
the matching ABI package, copy `jni/<abi>` into their native-library packaging,
copy `assets/starintel-edge` unchanged, and compile only the supplied thin
Kotlin binding. Product repositories do not vendor or edit the Lisp runtime.
