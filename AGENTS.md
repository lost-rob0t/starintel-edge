# StarIntel Edge contributor contract

`lost-rob0t/starintel-edge` is the canonical upstream for reusable edge runtime code, Raspberry Pi/Linux hosts, Android, glasses (including Meta), and watches. Downstream repositories consume exact revisions; they do not own forked implementations of these behaviors.

Common Lisp owns runtime semantics. Preserve existing StarLang, `star.logic.api/1`, STAR URI, JSON-LD and applicable `ZARA-RUNTIME/1` contracts. Kotlin/Java adapt platform APIs and forward typed requests; never reimplement the Lisp runtime or language compiler. Existing server actors use Sento: extract/reuse rather than invent a second supervisor in this bootstrap.

This repository currently contains host contracts and platform facades, NOT complete device runtimes. Missing backends must return unavailable, never simulated readiness. SDK interfaces, fake tests and target-catalog entries do not establish hardware support. Never mark Android ART, ABCL, ARM boot, Meta SDK, or physical-device gates as passing from JVM or static tests.

Capabilities require device discovery, installed adapter support, current OS permission and policy authorization. Recheck on every privileged dispatch. Honor consent, recording indicators, revocation, foreground restrictions and battery/thermal limits. No hidden collection or bypasses.

Secrets: environment, OS wallet/keyring, or Emacs auth-source only. Do not write secret values to config, Nix store, source, generated artifacts or CLI arguments/history. Public reusable code stays here; tenant data, private policy and deployment inventories stay downstream.

Run `python3 tools/check_contracts.py`, `sbcl --script tests/runtime.lisp`, and the Kotlin test command in `docs/ROADMAP.md`. Full hardware gates remain separately required. Do not merge failing checks or describe an untested platform as supported.

<!-- BEGIN STARINTEL FLEET CONTRACT -->
## StarIntel 15-worker fleet contract

This repository participates in the StarIntel hourly worker fleet.

- **GitHub connector is the repository control surface for fleet automation.** Use the connected GitHub connector to read current `AGENTS.md`, repository files, issues, pull requests, branches, diffs, comments, reviews, and CI/check state, and for permitted writes. Attempt the connector before claiming GitHub repository access or mutation is unavailable.
- **Canonical StarIntel document authority is 0.10.1 generated from Star Language.** The source of truth is `lost-rob0t/star-lang/specs/starintel/0.10.1/core.star` and its generated artifacts. Consumer repositories must consume/pin generated output; they must not maintain a competing handwritten schema or revive 0.9.x as canonical authority.
- **Respect worker ownership.** SL01-SL05 own Star Language/compiler/schema domains; PA06-PA09 own Pro Actors/collection runtimes; SS10-SS13 own server/runtime/router/persistence/security; IR14-IR15 own cross-repo integration and release admission. Do not duplicate an in-flight branch or silently take over another worker's owned slice.
- **One writer per branch.** Re-fetch exact head/base immediately before mutation. Reuse an existing retained branch/PR when it owns the task. Never force-push or overwrite concurrent work.
- **Evidence is exact-head.** Focused regressions should be RED before implementation and GREEN after it when executable locally. Required CI/checks must be observed on the exact candidate SHA; pending, skipped, stale, foreign, mock-only, or unrun evidence is not green.
- **No status-only escape hatch.** If the preferred task is blocked, record the precise blocker and advance another executable issue within the repository/worker scope.
- **Scheduled fleet tasks stay enabled.** Repository work must not disable a scheduled worker unless the operator explicitly asks for that task to be disabled.

Repository-specific rules in this file still apply; when they are stricter, follow them unless they conflict with the canonical StarIntel 0.10.1 authority above or an explicit current operator instruction.
<!-- END STARINTEL FLEET CONTRACT -->
