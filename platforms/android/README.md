# Android foreground-service host

This source reuses the existing ECL/LMDB/JNI runtime at
`f801b024965488c21f93c52a1a9fd2aecd224700`. It adds an Android library and diagnostic
service app, not another Lisp implementation or a remote proxy. **Debug APK/AAR
builds and host-ECL tests pass; ART service acceptance remains open.** Full star-server HTTP/CouchDB/RabbitMQ
is still absent; [the remaining portability checklist](../../docs/ANDROID-SERVER-PORTABILITY.md)
keeps that end goal explicit.

## Runtime and initialization

- `edge-service` hosts the backend in the app-owned non-exported
  `:starintel_runtime` process. One process-wide executor owns native boot, requests
  and stop on the same stable thread, including across Service recreation.
- `AndroidEclBackend` calls only the supplied `StarIntelEdgeRuntime` JNI binding.
  Missing native libraries are unavailable. ABI mismatch, stale assets, failed
  initialization and failed readiness never become RUNNING. Managed cleanup failure
  is reported honestly, retains owned actor/component handles until confirmed,
  blocks restart and uses the private-process recovery boundary.
- Copies only packaged `lisp/` and `ecl/` code trees. Old generated code is removed
  before extraction so stale ASDF files cannot survive an upgrade. Files/count/depth
  and total bytes are bounded; cancellation is checked during extraction.
- Preserves `getNoBackupFilesDir()/runtime/init.lisp` and all state outside those
  generated code trees. The real `.lisp` template starts no peers/listeners. Existing
  init files are never overwritten; symlinks and files over 1 MiB are rejected.
- Packaged startup source-loads the pinned runtime, then loads **only the fixed
  trusted local init path**. Lisp starts the existing managed Sento actor component
  plus explicitly configured `star.edge.android:*service-components*`.
- Readiness checks both `runtime.ping` and `service.status`. The latter requires a
  running managed actor profile and completed init. It explicitly reports that
  the full server API and Android mesh integration remain unavailable.
- `service.stop` releases managed components. The C adapter also calls the fixed
  graceful-stop hook before `cl_shutdown`. No eval, arbitrary load, symbol name,
  executable path or class name is accepted through service intents or JSON.

`init.lisp` is executable trusted operator code, **not a sandbox**. Never load a
peer-supplied or external-storage init file. Keys/passwords/tokens belong in future
Android Keystore-backed trusted ports, not init/source/config. The app disables
backup; library consumers must preserve this exclusion. No secret values are
persisted by the host, and startup conditions are redacted.

The retained `EdgeHost.kt` is the existing typed request facade. Java owns only
platform resource lifetime; Lisp owns actor, policy, language and component semantics.
Private ZeroMQ mesh is separate optional component work, with no automatic pairing,
external connections or public swarm. This slice creates no HTTP listener; the
future HTTP host defaults to loopback and still requires authentication.

## Android lifecycle

- Start requires an explicit action in the visible app and visible notifications.
  On API 33+, granting POST_NOTIFICATIONS does not silently start the runtime;
  the user taps Start again. Notifications can stop the service.
- Uses `specialUse`, with the exact use case declared in the manifest. Play review
  is still required if distributed through Play. This is not an always-on exemption.
- Promotes before native initialization; repeated Start/Stop cannot queue unbounded
  work. Cancellation closes late startup results instead of announcing readiness.
- Keeps the notification through cleanup. Failed cleanup blocks another runtime.
  A 30-second startup / 10-second shutdown watchdog may terminate **only its own
  process after verifying the expected process name**, never the UI or arbitrary PIDs.
  Actual native timeout/recovery behavior is still unverified on Android.
- Live status uses Messenger IPC. Opening the diagnostic can bind an idle service
  for status, but only Start invokes Lisp. Disconnection never promotes persisted
  RUNNING to live state. Diagnostic persistence contains redacted enum values only.
- `START_NOT_STICKY`, no boot receiver, alarm, jobs, silent runtime restart, wake lock
  or battery-exemption request. A later explicit Start preserves the same init.
- No sensor/identifier/recording capability. Notification revocation requests stop.
  Doze, thermal limits, OEM policy or the user can stop or suspend network work;
  foreground service status never guarantees permanent availability.

## Build

Configured: AGP 9.4.0, Gradle 9.6.0, JDK 17+, SDK 36, Build Tools 36.0.0, min SDK 26.
The existing native flake uses ECL 26.5.5 / NDK 28.2.13676358 for arm64-v8a and x86_64.
No wrapper, SDK or binary runtime is silently downloaded by repository scripts.
With an already approved/installed toolchain and a bundle built from this source:

```sh
nix build .#android-runtime-x86_64 --out-link result-edge-runtime
cd platforms/android
gradle --offline --rerun-tasks -Pstarintel.edge.runtimeRoot="$(realpath ../../result-edge-runtime)" \
  :edge-service:assembleDebug :diagnostic:assembleDebug :diagnostic:lintDebug
```

The property is a local artifact path, not a URL. No bundle means the app can compile
but fails unavailable at startup. An old f801 bundle lacks the new trusted service
bootstrap and is not sufficient. **Use `--rerun-tasks` or a clean isolated output
directory whenever changing runtime bundles.** Nix-preserved file timestamps can
otherwise make downstream Gradle packaging reuse stale native/assets output even
after merge tasks run. Always verify the packaged `.so`, `.fas`, Lisp assets and
ABI against the intended bundle hashes; a successful task is not that proof.
Existing upstream native diagnostic remains a separate artifact.

## Checks and pending acceptance

```sh
tools/test_android_host.sh
python3 tools/check_contracts.py
sbcl --script tests/runtime.lisp
sbcl --script tests/android/service-runtime.lisp
sbcl --script tests/android/service-safety.lisp
python3 scripts/sync-starintel-schema.py --offline
```

JVM tests use fake native ports and actual host file I/O. Real SBCL/Sento tests prove
Lisp init, managed actor start, local round trip, data-only dispatcher and graceful
stop. Separate real ECL tests now cover the native ABI, Unicode boundary and exact
packaged source bootstrap. Both native ABIs build, Kotlin/Java compile and lint
passes with warnings; none of those establishes ART lifecycle behavior. See
[current evidence](../../docs/ANDROID-SERVICE-EVIDENCE.md).

Pending device tests include rotation/rebinding, repeated Start/Stop, Stop during
boot, native hang, notification stop/denial/revocation, task swipe, process kill,
force-stop/reboot, offline restart, Doze and private-state preservation. ART, queue
durability, actual encrypted mesh and full server integration must still pass
before calling this a running Android star-server.

## Primary references (checked 2026-10-04)

- [Foreground start restrictions](https://developer.android.com/develop/background-work/services/fgs/restrictions-bg-start)
- [Special-use service type](https://developer.android.com/develop/background-work/services/fgs/service-types#special-use)
- [User stopping foreground apps](https://developer.android.com/develop/background-work/services/fgs/handle-user-stopping)
- [Notification permission](https://developer.android.com/develop/ui/views/notifications/notification-permission)
- [Doze/App Standby](https://developer.android.com/training/monitoring-device-state/doze-standby)
- [Built-in Kotlin source sets](https://developer.android.com/build/migrate-to-built-in-kotlin)
- [AGP 9.4 compatibility](https://developer.android.com/build/releases/agp-9-4-0-release-notes)
