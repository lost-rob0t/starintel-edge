# StarIntel Edge contributor contract

`lost-rob0t/starintel-edge` is the canonical upstream for reusable edge runtime code, Raspberry Pi/Linux hosts, Android, glasses (including Meta), and watches. Downstream repositories consume exact revisions; they do not own forked implementations of these behaviors.

Common Lisp owns runtime semantics. Preserve existing StarLang, `star.logic.api/1`, STAR URI, JSON-LD and applicable `ZARA-RUNTIME/1` contracts. Kotlin/Java adapt platform APIs and forward typed requests; never reimplement the Lisp runtime or language compiler. Existing server actors use Sento: extract/reuse rather than invent a second supervisor in this bootstrap.

This repository currently contains host contracts and platform facades, NOT complete device runtimes. Missing backends must return unavailable, never simulated readiness. SDK interfaces, fake tests and target-catalog entries do not establish hardware support. Never mark Android ART, ABCL, ARM boot, Meta SDK, or physical-device gates as passing from JVM or static tests.

Capabilities require device discovery, installed adapter support, current OS permission and policy authorization. Recheck on every privileged dispatch. Honor consent, recording indicators, revocation, foreground restrictions and battery/thermal limits. No hidden collection or bypasses.

Secrets: environment, OS wallet/keyring, or Emacs auth-source only. Do not write secret values to config, Nix store, source, generated artifacts or CLI arguments/history. Public reusable code stays here; tenant data, private policy and deployment inventories stay downstream.

Run `python3 tools/check_contracts.py`, `sbcl --script tests/runtime.lisp`, and the Kotlin test command in `docs/ROADMAP.md`. Full hardware gates remain separately required. Do not merge failing checks or describe an untested platform as supported.
