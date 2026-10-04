# Private mesh verification record

Base: canonical schema migration `37c47b2`, composed with existing ECL runtime
`f801b024965488c21f93c52a1a9fd2aecd224700` and Android strict lifecycle fixes through
`0148106fd7d1ada0675488207b5da23080718188`. No generated schema files changed.

Observed locally, 2026-10-04, with pre-existing SBCL 2.2.9, CFFI, Bordeaux Threads,
Sento and libzmq (no dependency installation):

- `sbcl --script tests/mesh.lisp`: 98 synthetic core checks passed.
- `sbcl --script tests/mesh-zmq-contract.lisp`: 141 checks passed, including the
  above core checks, synthetic ZAP key mapping, immutable enrollment, pinned reply
  socket selection, ZAP enforcement options, wrong-thread rejection and fake-syscall
  finite-resource verifier cases, mapped reservations already above a lowered limit,
  retained permitted privilege, malformed kernel observations and limits changing
  during inspection. The actual loaded library reports CURVE support.
  No socket, handshake, encryption or actual finite-budget acceptance was exercised.
- `sbcl --script tests/mesh-runtime.lisp`: 120 checks passed, including core checks
  and real owned-thread lifecycle over synthetic transport. A blocked credential
  provider causes retained `:stop-failed` ownership; another owner is rejected;
  releasing the provider allows confirmed cleanup. No unsafe thread kill is used.
- `sbcl --script tests/mesh-sento-security.lisp`: 115 checks passed, including core,
  two real local Sento actors over synthetic transport, queued authenticated-peer
  revocation and conservative rejected-future handling. Captured default Sento
  stdout/stderr contains no synthetic secret marker from payload/handler failures or invalid raw handler returns.
- `tools/test_mesh.sh`: complete no-socket aggregate passed with an ASDF registry
  containing only pre-existing dependency trees. Test files register this checkout's
  own ASD explicitly. Counts above include repeated core checks and are not additive.
- ASDF loads/compiles the optional native, Sento and existing-runtime integration
  systems. `tests/mesh-zmq-loopback.lisp` compiles. A later authorized real-host
  attempt was **environment-blocked** before authentication/delivery acceptance;
  see below. It is not a passing encrypted-transport gate.
- Actual read-only native resource verifier returned NIL. `/proc/self/limits`
  reports soft and hard address-space limits as unlimited. No limit was changed.
- `python3 tools/check_contracts.py`: eight existing scaffold contracts passed.
- `sbcl --script tests/runtime.lisp`: 109 existing host/runtime checks passed.
- `python3 scripts/sync-starintel-schema.py --source <existing-star-lang-checkout>`:
  verified 0.10.1 at `d6ca8780845c4296f64ac8e65aaa9db143842460`.
- `git diff --check`: passed. Kotlin/device acceptance was not rerun in this slice;
  no Kotlin compiler is on its default PATH. Android integration owner runs its
  separate composed host/service gates.

## Environment-blocked attempt and unresolved acceptance

The real opt-in loopback test uses ephemeral in-memory keys, fixed local endpoints,
actual CURVE/ZAP, both-direction Sento requests and an observed ZAP denial counter
for an unknown key. It requires an already enforced qualifying resource budget
and an authorized socket-capable environment. This environment does not meet that
budget by default. With explicit approval, the mesh lane made one attempt in its
own unprivileged child with 2 GiB soft/hard address-space limits, 512 MiB SBCL
dynamic space and core dumps disabled. The parent limits were unchanged. libzmq
aborted with `Operation not permitted (src/ip_resolver.cpp:542)` before the
authentication/delivery acceptance checks. No pass or encrypted exchange is
claimed; no bypass or repeat attempt was made. No
dependency install, persistent key configuration,
push, publication, package promotion or device installation was performed.

Also unrun: hostile unfinished multipart/resource exhaustion containment, real
route-ID hijack/forged metadata and wrong-server-key cases, disconnect/reconnect
mutation ambiguity, cross-process restart/durable reconciliation, platform ABI/
CFFI DFFI packaging, Android/ECL transport execution and device/network lifecycle.
The code is experimental groundwork; these gates are not replaced by synthetic,
compilation, host-JVM, local actor or schema tests. See `PRIVATE-MESH.md`.

## Read-only verifier correction

The verifier additionally requires kernel `VmSize` <= the finite hard limit and
matches limit readback before/after inspection. It rejects CAP_SYS_RESOURCE in
permitted state even with effective state clear. The additional negative cases
are synthetic syscall/kernel-observation tests; no resource limits were changed
and no socket attempt was made for this correction. Raw VMA addresses are neither
read nor logged. The previously attempted real wire gate remains environment-
blocked at `Operation not permitted (src/ip_resolver.cpp:542)`; this change adds no
wire, flood-containment or Android acceptance claim.
