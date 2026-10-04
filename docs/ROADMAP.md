# Implementation and evidence gates

The repository now contains the canonical Sento actor runtime, managed lifecycle, durable outbox, Linux host backend, and reusable Android ECL/JNI runtime bundle with an Edge-owned diagnostic APK. Android foreground-service source is now in platforms/android, with current integration/acceptance evidence tracked separately. Product UI, watch APK, vendor SDK adapters, P2P protocol, and Raspberry Pi boot images remain separate work.

## Workstreams

1. **Common runtime + Raspberry Pi:** inventory existing Lisp actor/supervisor code and policy/transport integration; extract with provenance and existing tests; add native host, NixOS service, per-board images, offline recovery and ARM/boot gates.
2. **Android:** reuse the existing ECL/JNI binding to the shared Lisp API without rewriting semantics; build library and diagnostic APK; implement lifecycle/permission adapters, bounded durable outbox, local/offline operation and explicit optional relay; prove ART execution on real Android.
3. **Glasses + Meta:** implement the capability adapter API and official Meta DAT integration, then exact-device XREAL/VITURE/Android-glasses adapters. Model-specific display/input/capture, registration, permission revocation and disconnect handling require hardware evidence.
4. **Watch:** share the Android library; build a watch-local lightweight host, power policy, standalone/offline diagnostics and optional relay; test with phone disconnected and actual watch ART.
5. **Downstream migration/releases:** versioned artifacts and provenance, exact pins, consumers/compatibility tests, mirror policy, staged rollout and rollback. Do not remove prior source until consumers pass.

## Contract tests

```
tools/test_android_host.sh
python3 tools/check_contracts.py
sbcl --script tests/runtime.lisp
mkdir -p build
kotlinc platforms/android/EdgeHost.kt platforms/watch/WatchHost.kt platforms/glasses/GlassesHosts.kt tests/HostContractTest.kt -include-runtime -d build/host-tests.jar
java -jar build/host-tests.jar
```

No static, fake, host-JVM, or CI-only test substitutes for ARM boot, Android ART, ECL/JNI integration, watch battery/lifecycle or real glasses SDK/hardware tests. Nix expression evaluation/build is also a separate check from these host-contract tests.
