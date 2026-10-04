# Remaining star-server portability gates

The user's end goal is **star-server running locally as an Android service**.
This change advances that goal with the existing reusable ECL/Sento core. It does
not redefine the goal as a proxy or diagnostic app. HTTP/CouchDB/RabbitMQ parity
remains open; the service status explicitly reports `server-api: unavailable`.

## What executes Lisp in the integrated source

| Operation | Implementation | Current evidence |
| --- | --- | --- |
| Native boot | Existing ECL 26.5.5 / LMDB / JNI ABI 1 | Changed arm64/x86_64 bundles build; actual host ECL ABI and Unicode checks pass; ART remains open |
| Trusted initialization | Packaged startup loads fixed app-private `init.lisp` after the runtime source | Real SBCL test executes a synthetic Lisp side effect and preserves the file |
| Persistent local actor start | Existing `star.edge.runtime:start-runtime` + existing Sento actor system, with configured managed components | Real SBCL/Sento service-profile tests |
| Readiness | Closed `service.status`: running managed runtime, live actor-system handle, successfully loaded init; ping alone insufficient | Real Lisp dispatcher tests; native bridge orchestration tested with fake ports |
| Local actor round trip | Existing Sento routing, no network | Real host SBCL/Sento round trip; no new ART claim |
| Stop | Closed `service.stop`, plus native fixed graceful-stop hook before `cl_shutdown` | Real Lisp/native host and exact packaged-source tests pass; Android lifecycle unverified |
| Foreground notification/process watchdog/status IPC | Android Java platform adapter | Kotlin/Java compilation and debug APK/lint pass; actual Android lifecycle pending |
| Private mesh | Optional Lisp component under existing managed lifecycle | Real local Sento/thread tests over synthetic transport; not wired into Android native bundle |
| Full HTTP server | Not implemented in this service profile | Explicit unavailable status |

## Full-server checklist

1. **Common Lisp dependency closure on ECL/Android.** Port and run the real
   `starintel-gserver` ASDF dependency graph. It includes Ningle/Clack/Hunchentoot,
   CL+SSL, cl-rabbit, cl-couch, lparallel, Slynk and others. Do not mistake the
   smaller Edge/Sento bundle for this graph.
2. **SBCL-specific code.** Audit/replace implementation-specific time, deadline,
   MOP, POSIX and signal paths through maintained portability ports. Known examples
   in the inspected server are `source/lease-store-runtime.lisp`,
   `source/leases/valkey-store.lisp`, and `source/databases/couchdb.lisp`.
3. **Storage.** CouchDB is currently an external server dependency, while Edge
   ships LMDB and a separate file outbox. An LMDB adapter is an explicit architecture
   change with semantic/migration tests, not a silent CouchDB replacement. Prove
   transaction, index/query, crash recovery, capacity, corruption and Android
   fsync/durability behavior. The existing outbox's SBCL-only fsync is not ECL proof.
4. **Broker/leases.** RabbitMQ/cl-rabbit and optional Valkey assumptions need
   Android-buildable dependencies or explicitly approved compatible adapters.
   The new private ZeroMQ mesh must not silently replace broker/lease semantics.
5. **HTTP/auth.** Bind to `127.0.0.1` first, enforce authentication/authorization
   even on loopback (other apps can reach it), preserve canonical routes and
   error semantics, and run the server's actual HTTP integration suite. No
   unauthenticated LAN listener or public swarm by default.
6. **Canonical documents.** Carry the pinned StarLang 0.10.1 authority, typed CL
   builders/validators, limits and compatibility boundaries into the Android
   dependency closure; run producer/API conformance on the installed artifact.
7. **Secrets and trusted init.** Keep executable `init.lisp`, app-private and
   excluded from backup. Supply credential values through Android Keystore-backed
   trusted ports, never through request eval, peer code or literal source/config.
8. **Native ABI packaging.** Match ECL/LMDB/adapter/JNI and Lisp assets from the same
   verified build; test arm64-v8a and x86_64, target SDK 36, 16 KiB page alignment,
   startup/stop/error ownership and one stable native thread.
   Verify the new explicit Unicode codec and ECL-character conversion against the
   [native/ART matrix](ANDROID-NATIVE-ACCEPTANCE.md) before carrying payloads.
9. **Android lifetime.** Build the service APK; exercise actual ART startup,
   duplicate Start, interrupted boot, Stop, hanging native calls, process death,
   force-stop, reboot, permission/channel denial, Doze, thermal limits and offline
   state recovery. The private runtime process and watchdog are not yet device-tested.
10. **Private mesh and public swarm.** Private peers must be explicitly paired,
    authenticated and encrypted with bounded retries/queues and revocation.
    Android libzmq/CFFI packaging, transport loss and durable outcome handling need
    real tests. Public discovery/swarm is separate, disabled work.

## Prepared toolchain and remaining device gate

Already available here: Java 21 compiler module, GCC, make, Python, SBCL, the pinned
local Sento source dependencies, and exact Edge source `f801b024...` reconciled with
the local canonical migration. The user subsequently approved cloud build setup
and accepted the Android SDK license.

Prepared and used: Gradle 9.6.0, AGP 9.4.0, full JDK 21, Android SDK platform 36 /
Build Tools 36.0.0, Nix, ECL 26.5.5 and NDK 28.2.13676358. Updated ECL/LMDB/adapter
bundles build for both ABIs. All 20 packaged ELF modules resolve their required
libraries, have no build-host RPATH/RUNPATH and have at least 16 KiB LOAD alignment.
Use forced Gradle task reruns or clean isolated outputs when changing a bundle,
then verify final APK bytes: timestamp-preserved Nix files exposed stale downstream
Gradle package output in the first rebuild. An old bundle cannot satisfy the
changed service contract merely because compilation succeeds.

ADB, emulator and API 36 x86_64 system image are prepared. `/dev/kvm` is unavailable
in this environment; software-emulation attempts have not established an ART
service run. Physical-device acceptance needs separately authorized hardware. Phone
installation, signing, publication and external peer connections are not authorized
by approval to retrieve source or prepare a cloud build environment.
