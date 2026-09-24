# Downstream consumption contract

```
starintel-edge (canonical reusable source + device hosts)
    -> pinned Lisp library / Android AAR / watch library / image artifacts
    -> StarIntel server personality, Android/Wear OS products, Zara/Quasar clients
    -> starintel-universe / branded distributions / ROM overlays
    -> private infra and Biz fleet deployments
```

These arrows describe the required ownership/dependency direction, not integrations already landed. No existing downstream repository has been changed by this bootstrap.

Consumers pin the repository at an exact 40-character commit plus the release artifact digest. Verify signatures/provenance against configured trust roots and run both common conformance and target hardware gates before promotion. Keep the previous verified revision for rollback and test state-schema compatibility. Never deploy a floating branch merely because it has the right repository name.

Inventory old edge code before migrating: record source path, commit, license, current consumers and tests; extract without private data or secrets; add forwarding dependencies; prove equivalent behavior; only then retire duplicate source. Do not transplant entire server or product UI trees into this repository. Shared STAR URI/specification/StarLang libraries keep their own authority and are dependencies, not vendored reimplementations.

Downstream may select features, adapters, branding, policy and hardware profiles. Runtime bugs, reusable platform adapters and generic fixes land upstream here first. Private policy, tenant data, fleet inventory, credentials and promotion control never belong in this public repository.
