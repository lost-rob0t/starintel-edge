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

## Bootstrap status

Repository authority and platform scope are established. Runtime foundation,
conformance tests, platform bridges, and downstream integration are being added
as reviewable changes. No APK, Raspberry Pi image, vendor hardware certification,
or production-ready distributed runtime is claimed by this initial commit.

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
