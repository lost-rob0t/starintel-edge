# Implementation and evidence gates

The bootstrap implements only a Lisp forwarding/admission contract, JVM-compilable platform facades, a JSON-LD target catalog, documentation and contract tests. The default backend is unavailable. It does not implement the actor engine, ABCL loader, Android service/APK, watch APK, vendor SDK adapter, P2P protocol, durable outbox or Raspberry Pi boot image.

## Workstreams

1. **Common runtime + Raspberry Pi:** inventory existing Lisp actor/supervisor code and policy/transport integration; extract with provenance and existing tests; add native host, NixOS service, per-board images, offline recovery and ARM/boot gates.
2. **Android:** bind ABCL to the shared Lisp API without rewriting semantics; build library and diagnostic APK; implement lifecycle/permission adapters, bounded durable outbox, local/offline operation and explicit optional relay; prove ART execution on real Android.
3. **Glasses + Meta:** implement the capability adapter API and official Meta DAT integration, then exact-device XREAL/VITURE/Android-glasses adapters. Model-specific display/input/capture, registration, permission revocation and disconnect handling require hardware evidence.
4. **Watch:** share the Android library; build a watch-local lightweight host, power policy, standalone/offline diagnostics and optional relay; test with phone disconnected and actual watch ART.
5. **Downstream migration/releases:** versioned artifacts and provenance, exact pins, consumers/compatibility tests, mirror policy, staged rollout and rollback. Do not remove prior source until consumers pass.

## Contract tests

```
python3 tools/check_contracts.py
sbcl --script tests/runtime.lisp
mkdir -p build
kotlinc platforms/android/EdgeHost.kt platforms/watch/WatchHost.kt platforms/glasses/GlassesHosts.kt tests/HostContractTest.kt -include-runtime -d build/host-tests.jar
java -jar build/host-tests.jar
```

No static, fake, host-JVM, or CI-only test substitutes for ARM boot, Android ART, ABCL integration, watch battery/lifecycle or real glasses SDK/hardware tests. Nix expression evaluation/build is also a separate check from these host-contract tests.
