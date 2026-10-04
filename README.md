# StarIntel Edge

**Canonical upstream:** https://github.com/lost-rob0t/starintel-edge

This repository owns the reusable StarIntel edge runtime and its platform hosts:
Raspberry Pi/Linux SBCs, Android, smart glasses (including Meta integrations), and
watches. Downstream distributions and products consume pinned revisions of this
repository; they must not maintain independent copies of edge runtime behavior.

This repository also ships a custom, headlessly installable StarIntel
distribution with `edge`, `actors`, and `full` profiles. The Edge profile uses
ZeroMQ and the embedded Tek9/LMDB database rather than RabbitMQ. See
[the distribution and actor-package contract](docs/DISTRIBUTION.md).

Attax-OS uses a typed Common Lisp system API for geo providers, Wi-Fi and
Bluetooth recon, canonical StarIntel document ingest, managed actor services,
and the canonical Hackmode adapter. Plans target Debian, NixOS, and Termux;
missing platform providers remain unavailable. Lish is the configured default
shell, pending an immutable source/package pin for image bundling.

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
| `distro/` | Headless installer, actor package format, embedded ingest, and NixOS module |

## Target families

| Target | Execution model | Initial acceptance gate |
| --- | --- | --- |
| Raspberry Pi / Linux SBC | Local Common Lisp host; Nix packaging | Native and ARM boot/runtime tests |
| Android phone / tablet | Local Common Lisp through the reusable ECL/JNI runtime bundle | Android ART startup, lifecycle, offline, permission tests |
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

**Android runtime:** the ECL/LMDB/JNI bundle and native diagnostic source are
present, with prior upstream evidence in [ANDROID-RUNTIME.md](docs/ANDROID-RUNTIME.md).
A user-controlled foreground service and diagnostic app source are being integrated
with that core. See [current service evidence](docs/ANDROID-SERVICE-EVIDENCE.md).
This is not full star-server HTTP/CouchDB/RabbitMQ parity or new device acceptance.

**Not yet implemented:** watch APKs, vendor SDK bindings, Raspberry Pi boot images,
private mesh integration or public swarm. Desktop tests are not Android/device evidence.

| Remaining work | Tracking |
| --- | --- |
| Raspberry Pi/Nix service and hardware boot evidence | [#2](https://github.com/lost-rob0t/starintel-edge/issues/2) |
| Android local ECL runtime service and diagnostic APK | [#3](https://github.com/lost-rob0t/starintel-edge/issues/3) |
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

## StarIntel document contract

See [the pinned 0.10.1 boundary](docs/STARINTEL-0101.md).

## Experimental private actor mesh

[Private mesh](docs/PRIVATE-MESH.md) adds optional Common Lisp/Sento request routing,
explicit peer enrollment, bounded volatile delivery, and a CURVE/ZAP ZeroMQ adapter.
Trusted local `init.lisp` is preserved. Public discovery/swarm mode is disabled.
The real encrypted-host attempt was environment-blocked; Android acceptance remains open. Missing native
libraries, credentials or verified process containment fail closed. The synthetic
contract/actor tests do not establish a working device or production mesh.
