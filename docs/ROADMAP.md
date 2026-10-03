# Implementation and evidence gates

The bootstrap implements only a Lisp forwarding/admission contract, JVM-compilable platform facades, a JSON-LD target catalog, documentation and contract tests. The default backend is unavailable. It does not implement the actor engine, ABCL loader, Android service/APK, watch APK, vendor SDK adapter, P2P protocol, durable outbox or Raspberry Pi boot image.

## Workstreams

1. **Common runtime + Raspberry Pi:** inventory existing Lisp actor/supervisor code and policy/transport integration; extract with provenance and existing tests; add native host, NixOS service, per-board images, offline recovery and ARM/boot gates.
2. **Android:** bind ABCL to the shared Lisp API without rewriting semantics; build library and diagnostic APK; implement lifecycle/permission adapters, bounded durable outbox, local/offline operation and explicit optional relay; prove ART execution on real Android.
3. **Glasses + Meta:** implement the capability adapter API and official Meta DAT integration, then exact-device XREAL/VITURE/Android-glasses adapters. Model-specific display/input/capture, registration, permission revocation and disconnect handling require hardware evidence.
4. **Watch:** share the Android library; build a watch-local lightweight host, power policy, standalone/offline diagnostics and optional relay; test with phone disconnected and actual watch ART.
5. **Downstream migration/releases:** versioned artifacts and provenance, exact pins, consumers/compatibility tests, mirror policy, staged rollout and rollback. Do not remove prior source until consumers pass.

## Reproducible Nix entry points

The root flake pins nixpkgs to immutable commit
`c93b0882c7def157c311ca297d30f18bc4e23e49` and commits the resolved
`flake.lock`. It exports the host-contract package, development shell,
formatter, and checks for `x86_64-linux` and `aarch64-linux`.

```sh
nix develop
nix build .#edge-host-contract
nix flake check
nix flake check --all-systems --no-build
```

CI runs the same locked flake. The all-systems command is an evaluation gate on
the hosted x86_64 runner. It does not count as an aarch64 build or Raspberry Pi
boot test. A native aarch64 builder or CI runner remains required before the ARM
acceptance gate can be marked complete.

## Contract tests

The canonical host-contract test command is:

```sh
./tools/check-host-contracts
```

Inside the Nix development shell, that command runs the Python metadata checks,
the Common Lisp forwarding/admission tests, and the Kotlin/JVM facade contract
tests. The Nix check invokes the same script explicitly through the pinned Bash
toolchain, so it does not depend on a host `/usr/bin/env`.

No static, fake, host-JVM, or CI-only test substitutes for ARM boot, Android ART, ABCL integration, watch battery/lifecycle or real glasses SDK/hardware tests. Nix expression evaluation/build is also a separate check from these host-contract tests.
