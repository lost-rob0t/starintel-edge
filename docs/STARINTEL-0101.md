# StarIntel 0.10.1 consumer boundary

The sole document authority is lost-rob0t/star-lang at commit
9198370f7a6f3e2a5ea00af3efdb6d705e102650, generated from core.star. The complete
release is vendored in schemas/starintel-0.10.1 and hashed by the consumer lock.
Verify with `python3 scripts/sync-starintel-schema.py --source /path/to/star-lang`.
Never edit generated contracts or infer semantics from version labels.

The current edge host forwards requests and exposes capability facades. It has
no StarIntel document producer, store or validator. Its target catalog JSON-LD
is not a document corpus and must not be relabeled 0.10.1. Future adapters must
consume this release at their document boundary. This pin does not enable any
missing backend or establish hardware support. Existing hardware gates remain.

## Published authority provenance

The published authority commit above has Git tree
`c8c83976e419af1f380df41b3351e6f1875cf4d8`, identical to the previously tested
local authority commit `d6ca8780845c4296f64ac8e65aaa9db143842460`.
This publication repair changes only the immutable source identity in the
consumer lock and workflow; every vendored source, generated schema, manifest,
fixture and release-lock byte remains unchanged. Earlier evidence documents
retain the local commit used by their original runs. StarLang-generated 0.10.1
remains the sole normative contract; legacy fixtures are test inputs only.
