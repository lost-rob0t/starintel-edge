# Canonical document subprocess interoperability

`tests/interop/test_documents.py` runs actual SDKs in independent producer and
consumer processes. It forwards the producer's NDJSON stdout unchanged into every
consumer, then checks values, types, field absence and exact integers. The test
orchestrator never substitutes its validator for a language implementation.

## Authority and scope

StarLang `d6ca8780845c4296f64ac8e65aaa9db143842460`, generated StarIntel 0.10.1,
is the single normative contract. Every SDK schema and portable manifest must
match Edge's authority lock by SHA-256 before any test can run. Legacy workflow
oracles are test inputs, never an alternate writer specification. Canonical
writers reject other schema versions rather than relabeling input.

Five entry points form 25 directed cells, including 20 cross-language cells and
five self controls:

- Python: real canonical SDK and generated checked document types
- Common Lisp/SBCL: real SDK generated decode/encode boundary
- Nim: real maintained validation SDK and exact JSON wire API (strict syntax, raw-number preservation, symbolic bounds)
- JavaScript: real SDK lossless JSON parser/serializer and validator
- TypeScript: independently compiled strict typed entry point using the actual
  SDK declarations and JavaScript runtime

TypeScript is not a fifth independent runtime implementation. Nim's full all-90
generated typed-codec build was killed (exit -9) in this environment; the matrix
makes no claim that it passed. Its supported validation/JSON wire path is tested.
Java/Kotlin/C/JNI are Edge actor/platform interfaces, not canonical document SDKs.
No executable 0.10.1 document adapters were found for Go, Rust, Emacs Lisp or
Prolog; authority's portability commitment is not executable interop evidence.
See the separate actor report for actual actor boundaries. These process tests
prove neither a real encrypted mesh connection nor Android ART/device execution.

The corpus includes every persistent dtype, canonical research and workflow
fixtures, non-BMP/BMP Unicode, embedded NUL, absent fields, nested null/false,
empty arrays, integers above JavaScript's safe-number range, signed 64-bit limits,
fractional JSON numbers, decimal strings, and enum/reference/version violations.
Invalid inputs are deliberately serialized without producer validation and must
be rejected by the consumer. This verifies hostile-wire rejection, not a claim
that valid SDK writers intentionally emit invalid documents.

## Reproduction (existing dependencies only)

Provide explicit local checkout paths; no downloads or installations occur:

```sh
python3 tests/interop/test_documents.py \
  --python-sdk "$PYTHON_SDK" --cl-sdk "$CL_SDK" \
  --nim-sdk "$NIM_SDK" --js-sdk "$JS_SDK" \
  --python python3 --sbcl sbcl --nim nim --node node \
  --output /tmp/edge-document-interop
```

Prerequisites: Python with that SDK's existing dependencies (`jsonschema`),
SBCL/ASDF with `com.inuoe.jzon` and `cl-ppcre` source closure, Nim >=2 and its C
compiler plus PCRE shared library, and Node with the JS SDK's installed
`ajv`, `ajv-formats`, `lossless-json` and TypeScript compiler. Use the environment's
normal `CL_SOURCE_REGISTRY`, `SBCL_HOME`, and `LD_LIBRARY_PATH` as needed.

The SDK checkout IDs used for the recorded local run are recorded in the JSON
result. Their remote availability has not been verified. They must not silently
be substituted with older revisions or copied schemas in CI. Missing SDKs,
tools or authority hash mismatches are hard failures, not skips. The existing
Edge host CI workflow does not execute this matrix; green host CI is not matrix
coverage. Enabling remote CI requires separately available exact SDK revisions
and explicitly provisioned dependencies.

Output: `document-matrix.json` contains the per-cell result, fixture names,
SDK revisions, authority hashes and scope. `*-valid.ndjson` preserves each
producer's actual wire bytes for inspection. All records are synthetic.

## Explicit version migration interoperability

When the separately reviewed authority compatibility reference is available,
include its real migration outputs with
`--fixtures "$STARLANG/specs/starintel/compatibility/canonical-migration-fixtures.json"`.
This does not introduce a second canonical writer contract or silently translate
versions in a SDK. The additional canonical fixtures must pass every matrix cell.

Then run:

```sh
python3 tests/interop/test_migration_restore.py \
  --reference "$STARLANG/specs/starintel/compatibility" \
  --matrix-output /tmp/edge-document-interop
```

This verifies source-locked migration fixtures, checks the actual wire evidence
hashes, and invokes the explicit archival reference's restore API to recover the
original historical bytes. It does not claim that each SDK has a legacy reader,
or that an edited canonical document can be reverse-migrated. Versions other than
the explicitly implemented reader profiles remain unsupported.

## Earlier portable-corpus host result (2026-10-04)

- All 25 directed cells passed: 149 valid cases and 14 rejection cases per cell.
- 3,725 successful producer-to-consumer exchanges; 350 hostile-wire rejections.
- All 90 persistent document types plus 28 explicit migration outputs covered.
- 140 exact historical-byte restores passed (28 original inputs × 5 producers).
- Seven harness regression checks passed, including optimized-Python refusal and
  a synthetic SDK programming exception that must fail instead of count as denial.
- Full Nim generated typed-codec compile was killed (exit -9); only its maintained
  validation plus native JSON wire path is included in the passing matrix.

Machine-readable evidence is in `evidence/document-matrix.json` and
`evidence/migration-restore.json`. Harness digests, actual SDK revision IDs,
clean tracked-worktree checks, generated-contract digests, producer wire digests
and tool versions are recorded. Original producer wires remain local synthetic
evidence and are not committed.

This run used the historical local authority commit `d6ca878...`; the publication
coordinator subsequently verified the byte-identical authority tree published at
`9198370f7a6f3e2a5ea00af3efdb6d705e102650`. The report retains the actual tested
revision, rather than retroactively claiming a different commit was executed.
The restore checker compares canonical schema/manifest bytes and separately
records both authority revision labels, permitting such byte-identical publication.

## Numeric blockers discovered after the first matrix

The passing fixture matrix is NOT a complete arbitrary-number interoperability
claim. `evidence/numeric-boundaries-before-fix.json` records three additional
schema-valid raw-number probes across all five entry points:

- Nim rejects `createdAt: 9223372036854775808`, although the canonical schema has
  no signed-64-bit maximum and the other adapters accept it.
- Python, Common Lisp and Nim round the opaque extension number
  `0.12345678901234567890123456789`; JavaScript/TypeScript preserve its value.
- The larger opaque integer `9223372036854775809` survives all five adapters.

`tests/interop/test_numeric_boundaries.py` returns a failing exit status for
these divergences. They are not expected failures or successful skips. Fixes
must preserve the schema's domain rather than adding a convenient int64 bound.
These failures drove local SDK fixes and the expanded matrix below. Earlier
results remain exact pre-fix evidence, not retroactively relabeled.

A further raw-number check also found JavaScript/TypeScript rejecting the valid
opaque JSON number `1e400` because their structural validator projected it into
a native infinite float. The lossless parser itself preserved the token. This
was an additional numeric-domain blocker fixed locally, not an authority
restriction on exponent size.


## Expanded exact-wire result after local SDK fixes

All 25 directed cells pass against these clean, local SDK commits:

| SDK | Commit |
| --- | --- |
| Python | `5096ab039cb240aae0057fbed8ae6a7667321bbf` |
| Common Lisp | `9f365eab1088242355686b640054a935c2b8a7f4` |
| Nim | `26f9fb4fbd54c4d72fc57c7450954a4fed3b6fec` |
| JavaScript / TypeScript runtime | `8b15b2e0eb4d5562979a8d9b0565fe6eb70b82c4` |

Each cell checks 155 regular valid documents, 14 regular rejection cases,
10 raw-number valid cases and 5 exact-number rejection cases. Total: **4,125
successful exchanges and 475 rejection checks**. All 90 persistent dtypes and
34 migration outputs are covered (28 workflow fixtures plus six numeric-notation
variants). Ten harness safety regression tests pass. Exact archival recovery was
verified after every consumer output: **850 byte-exact restores** across 25 paths.

The expanded gate forwards actual raw producer bytes for both ordinary and
numeric corpora. Its independent oracle normalizes coefficient/power symbolically,
without Python float rounding, Decimal exponent limits, or exponent-sized powers.
Cases include `1e400`, `1e-400`, `1e999999999999999999999`, tiny symbolic exponents,
int64+1, exact integral `1.0` / `1e0`, and a near-integer fractional tail that must
reject. It also checks ordinary opaque keys named `__proto__`, `constructor`,
and `isLosslessNumber`, fixing discovered JS parser/serializer confusion.

Actual public wire APIs are Python `parse_json` / `stringify_json`, Lisp
`parse-json` / `stringify-json`, Nim `parseWireJson` / `roundtripWireDocument` /
`stringifyWireJson`, and JS/TS `parseJson` / `stringifyJson`. Already-rounded
caller-supplied native floats cannot be reconstructed; use these APIs at the
first and last JSON wire boundaries.

`evidence/document-matrix.json` records this final expanded run and exact source
hashes. `document-matrix-before-numeric-fixes.json` retains the earlier narrower
run. This evidence records local execution, not a remote CI result. Existing remote
host CI does not execute this complete matrix. Android ART, real encrypted network
transport, generated typed Nim unbounded-number storage, and JVM embedding safety
remain distinct acceptance gates; see the actor report.

The exact-wire proof is not a claim that native generated field primitives are
arbitrary-precision containers: generated TypeScript numeric fields still use
`number`, and Nim typed fields still use `int64`. Preserve incoming exact values
through the tested SDK wire representations; assigning a value to an already
rounded machine primitive loses information before serialization. Broader typed
binding representation changes require separate generator/release work.


The final restore proof uses the notation-independent authority reference at
`ff8768960949d9ff7756760ca961e3ccd0bb1e9a`. Equivalent JSON numeric spellings
(`1e3`/`1000`, `1.0`/`1`, signed zero, and enormous exponent aliases) no longer
invalidate a receipt. Changed values, strings substituted for numbers, booleans,
and forged receipt details still reject. Include both numeric fixture files:

```sh
# Add to test_documents.py:
--fixtures "$STARLANG/specs/starintel/compatibility/numeric-canonical-migration-fixtures.json"
# Add to test_migration_restore.py:
--canonical-fixtures "$STARLANG/specs/starintel/compatibility/numeric-canonical-migration-fixtures.json" \
--historical-fixtures "$STARLANG/specs/starintel/compatibility/numeric-historical-reader-fixtures.json"
```

The restore report records the actual reference commit and every Python reference
source hash. The document report records each consumer wire hash; consumer bytes
are never reconstructed through the orchestrator before restoration.
