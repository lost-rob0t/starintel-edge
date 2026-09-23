# ADR 0001: Canonical edge source authority

Status: accepted by repository owner on 2026-09-23.

## Decision

All reusable StarIntel edge code lives in `lost-rob0t/starintel-edge`: the shared Common Lisp runtime integration, Raspberry Pi and Linux/SBC hosts, Android runtime host, glasses adapters (native and companion), Meta integration, and watch runtime host. This is the upstream that later canonical downstream distributions pull from.

Source ownership is independent of the larger `starintel-universe` distribution layout. That repository may pin/submodule this one; it must not become a second runtime implementation owner. GitHub/Forgejo mirrors are mirrors of the same source lineage, not competing upstreams.

## Boundaries

| Here | Downstream |
| --- | --- |
| Runtime host ABI, portable Lisp integration and conformance tests | Server-only persistence/ingest and server personality |
| Platform permissions/lifecycle, native bridges, device capability adapters | Android field-client UI, Wear OS product UI, Quasar and Zara UI |
| Generic Nix packaging and board/image definitions | Fleet inventory, branded images, infrastructure/CD and private tenant policy |
| Generic pairing/transport/update clients and policy hooks | Trust roots, actual enrollment, budgets, credentials and production promotion |

One behavior has one implementation owner. An extraction must identify the original files and their license, preserve history/provenance, move their tests, and replace the old entry point with a forwarding dependency. Do not delete working source before consumers pass equivalent tests.

The existing server documentation identifies Sento as its local actor runtime. The initial host facade deliberately does not create another actor engine. Shared Lisp actor/supervisor extraction and ABCL integration are explicit follow-up gates, not features implemented by this facade.

## Platform model

A native host executes the common runtime locally. A companion host executes it on a phone/compute node while a paired accessory contributes capabilities. An accessory is not advertised as an independently executing node. Meta starts as an Android companion integration through the official SDK. Individual models may expose display, camera, input or audio capabilities differently; discover them rather than infer them from a brand name.

A Wear OS runtime is a first-class target, not just the existing phone configuration companion. Its desired acceptance test includes disconnected operation. Do not advertise standalone execution until the actual watch-local backend passes.

## Canonical dependencies

Keep the canonical StarIntel JSON-LD specification and shared STAR URI libraries in their existing authoritative repositories. This repository's target catalog is local build/adapter metadata, not a new StarIntel document dtype or alternative STAR URI grammar. Preserve `star.logic.api/1` and applicable `ZARA-RUNTIME/1` integrations.

## Release contract

Downstream pins exact commits/artifact digests, verifies provenance, runs conformance and device gates, and promotes explicitly. Tags alone are not immutable artifact verification. Public generic fixes land here first; downstream contributes back rather than copying files. No floating `main` in production. Private policy and secrets must never be imported during source extraction.
