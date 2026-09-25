# StarIntel Edge

**Canonical upstream:** https://github.com/lost-rob0t/starintel-edge

This repository owns the reusable StarIntel edge runtime and its platform hosts:
Raspberry Pi/Linux SBCs, Android, smart glasses (including Meta integrations), and
watches. Downstream distributions and products consume pinned revisions of this
repository; they must not maintain independent copies of edge runtime behavior.

## Ownership

- Common Lisp owns shared runtime semantics and APIs. Prolog/StarLang supply policy
  through their existing shared contracts. Kotlin/Java are platform bridges, not
  alternate Lisp, StarLang, or actor implementations.
- Device-specific lifecycle, permissions, sensors, transports, and packaging belong
  here. Server-only storage/ingest belongs in `starintel-server`; field-client UI,
  branding, private policy, fleet configuration, and deployment remain downstream.
- `starintel-biz`, infrastructure, `starintel-universe`, Android/Wear OS products,
  and ROM overlays pull versioned artifacts or exact source revisions from here.

See [ADR 0001](docs/ADR-0001-canonical-upstream.md) and the
[downstream consumption contract](downstream/README.md).

## Source layout

| Path | Responsibility |
| --- | --- |
| `runtime/` | Shared Common Lisp host contract and reusable runtime integration |
| `platforms/rpi/` | Linux/Raspberry Pi host and generic Nix/board packaging |
| `platforms/android/` | Android runtime host and platform bridge |
| `platforms/glasses/` | Native and companion glasses hosts, including Meta |
| `platforms/watch/` | Wear OS lightweight local host and optional relay integration |
| `contracts/` | Local JSON-LD target catalog and acceptance gates |
| `tests/` | Common host and platform-facade conformance checks |
| `downstream/` | Pinning, source migration, release and consumer rules |

## Target families

| Target | Execution model | Initial acceptance gate |
| --- | --- | --- |
| Raspberry Pi / Linux SBC | Local Common Lisp host; Nix packaging | Native and ARM boot/runtime tests |
| Android phone / tablet | Local Common Lisp through the ABCL platform bridge | Android ART startup, lifecycle, offline, permission tests |
| Android-based glasses | Local host where the vendor permits installation | Per-device install and SDK conformance tests |
| Tethered/display glasses | Phone/compute-host runtime plus capability adapter | Per-device display/input/transport tests |
| Meta glasses | Android companion integration through official Wearables Device Access Toolkit | SDK/device/version-specific permission, session, capture and optional display tests |
| Wear OS watch | Local lightweight runtime plus optional phone relay | Watch ART startup, disconnected mode, power and lifecycle tests |

A target entry is **not a hardware-support claim**. Capability discovery must
report only what the installed adapter, device, permissions, and policy actually
allow. In particular, a companion adapter does not imply that custom runtime code
can be installed directly on Meta glasses. Display capabilities are model- and
SDK-dependent, not a blanket promise for all glasses.

## Runtime status

Implemented here: the Common Lisp forwarding/admission contract, Sento actor
supervision, managed lifecycle with startup rollback and graceful shutdown, a
bounded durable file outbox, a fail-closed power policy, the Linux host adapter,
typed Kotlin Android/watch/glasses facades, target-family records, and contract
tests. Missing device backends explicitly report unavailable; they do not
simulate working devices.

**Not yet implemented:** Android ECL/ART packaging, Android or watch diagnostic
APKs, vendor SDK bindings, Raspberry Pi boot images, P2P runtime, or downstream
migrations. Desktop JVM/contract tests are not Android, board, watch, or Meta
hardware evidence.

| Remaining work | Tracking |
| --- | --- |
| Raspberry Pi/Nix service and hardware boot evidence | [#2](https://github.com/lost-rob0t/starintel-edge/issues/2) |
| Android local ABCL runtime library and diagnostic APK | [#3](https://github.com/lost-rob0t/starintel-edge/issues/3) |
| Smart-glasses adapters and official Meta DAT integration | [#4](https://github.com/lost-rob0t/starintel-edge/issues/4) |
| Wear OS local runtime, offline mode and optional relay | [#5](https://github.com/lost-rob0t/starintel-edge/issues/5) |
| Pinned downstream artifacts, migration and release/promotion | [#6](https://github.com/lost-rob0t/starintel-edge/issues/6) |

[Implementation roadmap and test commands](docs/ROADMAP.md).

## Integration rules

Preserve the canonical JSON-LD StarIntel specification, shared STAR URI semantics,
`star.logic.api/1`, and applicable `ZARA-RUNTIME/1` integrations. Do not introduce
competing parsers or protocol authorities. Use injected effect ports and scoped,
revocable capabilities. Secrets come only from environment variables, OS
wallet/keyring facilities, or Emacs auth-source, never checked-in configuration,
Nix store paths, generated files, or CLI history.

Downstream releases pin an exact upstream commit and artifact digest, verify
provenance, and pass the same conformance suite before promotion. Compatibility
wrappers forward; reusable fixes land here first.
