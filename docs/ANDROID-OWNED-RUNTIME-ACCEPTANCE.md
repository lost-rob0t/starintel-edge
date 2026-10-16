# Owned Android ECL runtime slice

Base: `727f3505c0f9ac8be288a040e8a42c9bb4436887`. Tracks #3 and #8;
those issues' historical ABCL wording is superseded for this slice by the
operator's explicit ECL direction. Neither issue is closed by this work.

The service backend now selects `OwnedEclNativePort`, using the existing bounded
`OwnedEclProcess` protocol and lifecycle controller. Only the standalone runner
loads ECL. The managed JNI guard is unchanged. Startup checks the actual child
ABI handshake, ping, managed local-actors readiness and real Sento roundtrip.
Stopping checks the Lisp response, transport acknowledgement and zero child exit.
The existing service process watchdog remains conservative: after any boot attempt
it retires the exact service process, including on unconfirmed child retirement.
A nonblocking one-second child-liveness observation removes RUNNING after an
unexpected child exit; cleanup retains the existing watchdog ownership rules.
The controller regression failed with stale RUNNING before this repair and passes
afterward. Host transport tests also kill the exact owned C-stub child and observe
its death without issuing another request. No implicit retry, automatic restart
or alternate Lisp evaluator is introduced.

Both native ABI bundles build/hash the PIE runner alongside the matching adapter.
APK consumers must use extracted native libraries (`jniLibs.useLegacyPackaging =
true`); the diagnostic application does so. The trusted platform-provided
`ApplicationInfo.nativeLibraryDir` is the only executable directory. Generated
Lisp/ECL assets are replaced on boot; private init and state outside those trees
are preserved. No executable is copied into writable app data.

## Evidence levels

Local execution on October 16, 2026:

- `python3 tools/check_contracts.py`: 8 scaffold contracts passed.
- `python3 tests/android/test_owned_process.py --build-dir build/owned-host`:
  13 native framing tests, 84 Java ownership assertions and 20 new lifecycle
  integration assertions passed. **Host C stub only, no ECL/ART evidence.**
- `bash tools/test_android_host.sh`: 172 controller/init and 57 orchestration
  assertions passed; Python discovery passes after repairing import-time argument
  parsing. JNI header-dependent test is separately skipped in this workspace.
- `bash -n tests/android/run_emulator_test.sh` and `git diff --check` passed.

Local environment has no Nix, SBCL, ECL, Android SDK/emulator or `/dev/kvm`.
No local real-ECL, Lisp, Kotlin facade, APK, emulator or physical-device result is
claimed. Shell `gh auth status` rejects its token; the GitHub connector is used
for PR publication/status where necessary. Git transport is checked separately.

First CI attempt at `525b672` built both native ABI bundles successfully
([run 38939095178](https://github.com/lost-rob0t/starintel-edge/actions/runs/38939095178)),
then failed compiling the diagnostic Java source under Nix's US-ASCII locale.
The build now explicitly uses UTF-8. No emulator was launched in that attempt.

The `Android owned ECL runtime` workflow builds matched x86_64/arm64 bundles,
then installs an ephemeral diagnostic APK on one disposable API 36 x86_64 AVD.
It uses the production Android backend, without INTERNET permission, performs
boot/stop/new-child cycles, kills the exact ART parent with a live child, observes
child retirement, and restarts with identical private synthetic init/state.
Logs, source revision, APK digest, process snapshots and emulator properties are
retained even on failure. **A committed workflow is not a passing emulator result.**
The arm64 build does not establish arm64 execution or physical-device support.

The synthetic state sentinel is synced and read by real Lisp on each boot; it
checks preservation by the asset installer across process death. It does NOT
prove LMDB/outbox transactions, actor-state replay, power-loss durability or
canonical server persistence. Those gates remain open.

## Remaining canonical server slices

`docs/ANDROID-SERVER-PORTABILITY.md` remains authoritative. Rechecked against
canonical server `0137ead90ab9560b5a5090f0b62c1b59aac08c68`:
`source/starintel-gserver.asd` requires the full HTTP/auth/storage/broker closure;
`source/databases/couchdb.lisp:44` uses `sb-mop`,
`source/lease-store-runtime.lisp:17` uses `sb-ext:get-time-of-day`, and
`source/leases/valkey-store.lisp:215` uses `sb-sys:with-deadline`. None of these
ports is implemented by a local actor ping. In order:

1. Pass this standalone ART/ECL startup and lifecycle gate; verify production
   foreground-service lifecycle/notification denial and exact packaged bytes too.
2. Prove actual ECL/LMDB/outbox durable transactions, crash recovery and bounded
   actor-state restoration; replace SBCL-only fsync through a tested ECL port.
3. Build the canonical server ASDF closure (HTTP stack, TLS, cl-couch, cl-rabbit,
   lparallel and debugger dependencies); port SBCL deadline/POSIX/MOP paths.
4. Run canonical loopback HTTP routes and real auth/tenant denial tests. Other
   Android apps can reach loopback; no auth bypass is allowed.
5. Port storage/broker/lease dependencies or separately approve compatible
   adapters with semantic tests. LMDB is not an implicit CouchDB replacement;
   local Sento is not RabbitMQ. Preserve real acknowledgements and recovery.
6. Carry the verified canonical schema lock, producer validation and secrets
   ports. Only then update consumer pins with their conformance evidence.

No WearOS source/pin or PR #120 branch is modified. Full server API still reports
unavailable; no phone, host, live collection, credentials or services are deployed.

## Verification harness repair

The e9ef934 Android run stopped before ADB connected. Subsequent inspection of
its retained emulator log identified `FATAL: Broken AVD system path`: inherited
CI `ANDROID_HOME` selected the hosted SDK while `ANDROID_SDK_ROOT` selected Nix.
Both now select the flake SDK, and the harness checks image files, observes its
own emulator job during boot, emits emulator diagnostics and retains the signed
APK even when boot fails. This repair itself is not evidence of ART startup.

The host parent-death test had an independent EOF/SIGKILL race: parent exit closed
its pipe writer, permitting the runner's valid clean-EOF shutdown before signal
delivery. The test subreaper now retains the pipe endpoints, isolating the
parent-death signal while still requiring SIGKILL and reaping that exact child.
The repaired test passed 100 consecutive local executions. All host-only checks
passed; these do not establish Android ECL or database durability.
