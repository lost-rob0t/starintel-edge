# Private actor mesh: experimental vertical slice

This slice keeps trusted local `init.lisp`, Common Lisp runtime semantics and the
existing Sento actor registry/component lifecycle. It adds a bounded volatile
request/result path and an optional native ZeroMQ adapter. **It is not yet an
accepted deployable private mesh. The real encrypted-host attempt was environment-
blocked; Android gates remain unrun. Public swarm mode is rejected; there is no
discovery or public listener.**

## Existing authorities and scope

- `starintel-server/source/actors.lisp` and the reusable Edge `runtime/actors.lisp`
  own exact actor names and Sento registration. No second actor registry or
  supervisor is introduced. The resolver is injected, normally
  `star.edge.actors:get-dest-actor`.
- Auto-Research `STAR-SERVER-040-starrouter-zeromq-transport-api-overhaul` supplies
  operation/result, deadline, application-vs-transport identity, ownership and
  outcome-unknown semantics. `SENTO-ZMQ-000-zero-mq-transport-runtime` supplies the
  context/socket ownership model. This is a deliberately narrow experimental
  projection, not completion of either design or a replacement protocol authority.
- Current Nim StarRouter's `SC01`/`SR01` broker is an opaque legacy multipart
  transport without this private authentication/admission contract. This adapter
  does not claim legacy wire interoperability or silently weaken auth to provide it.
- Canonical StarIntel documents remain generated from StarLang 0.10.1 at
  `9198370f7a6f3e2a5ea00af3efdb6d705e102650`. Transport payloads are opaque octets:
  no parser, evaluator, document constructor, re-encoding or alternate schema.
  A real document actor must use the pinned generated contracts at its boundary.
- The existing durable Edge outbox is intentionally not used as transport
  durability: doing so needs persisted attempts/results and restart acceptance.
  This slice promises neither persistence nor exactly-once execution.

## Components and trusted initialization

ASDF systems are optional:

- `starintel-edge/mesh`: dependency-free shared semantics and wire validation
- `starintel-edge/mesh-sento`: existing Sento async asks and actor receive wrapper
- `starintel-edge/mesh-zmq`: CFFI/libzmq CURVE/ZAP transport
- `starintel-edge/mesh-runtime`: one transport owner under the existing Edge
  component lifecycle, with a bounded cross-thread ticket queue

`examples/private-mesh/init.lisp` shows explicit enrollment and a synthetic echo
actor. It contains credential-provider references only. It fails if the trusted
host has not supplied a credential provider. Do not put actual keys, passwords,
private inventories or tenant policy in upstream examples/source. No key is
created, saved or rotated by normal startup. Loading the system alone opens no
sockets. The example is not automatically loaded.

Android's existing startup loads the fixed app-private `init.lisp` and starts
actors before `star.edge.android:*service-components*`. An explicitly configured
mesh component can be added there; missing native prerequisites cause startup
failure, not a fake running mesh. The default local-actor service does not include
this component and its local readiness is not mesh readiness.

`make-mesh-component` returns `(values component handle)`. Add the component after
the actor component so reverse shutdown closes transport before actors. Keep
`star.edge.runtime:*require-confirmed-shutdown*` true during start **and every
stop/retry**. The Android service already does this. A failed/blocked component
startup remains owned by the strict lifecycle; failed joins report `:stop-failed`
and prevent replacement until cleanup is confirmed. No thread is killed unsafely.

Use `submit-to-mesh` from callers/Sento actors and `take-mesh-result` to retrieve a
ticket result. Submission is bounded, nonblocking and never exposes a socket.
The owned thread opens, polls and closes the transport, polls Sento futures and
sleeps between ticks. It never waits for an actor to finish during stop. Direct
`start-mesh`, `step-mesh`, `submit-request`, `take-result`, `suspend-mesh`,
`resume-mesh` and `stop-mesh` are lower-level owner-serialized APIs; native
wrong-thread calls are rejected before changing state.

The managed owner is an ordinary existing-runtime component, not a second process
supervisor or a Java/Kotlin runtime. One native socket owner/context per process
is enforced. The low-level two-peer test deliberately shares one owner/context;
normal deployments run one enrolled node per process.

## Private enrollment and authorization

Each node explicitly configures its node ID, private IPv4 TCP listener, peers'
private endpoints, peer public-key references, allowed asserted actor callers,
allowed local destination actors and operation/schema set. Only loopback and
RFC1918 IPv4 literals are accepted. DNS, wildcard/public listeners, IPC, public
swarm, automatic discovery, NAT traversal and rendezvous are not implemented.
Both peers must have mutually reachable configured listeners and enroll each
other. No network scanning is performed.

The local credential provider returns fresh 32-byte CURVE public/secret vectors
for the local reference, and only public-key material for peers. It is a trusted
OS keyring/environment/auth-source adapter, not a new secret store. Secret copies
used for socket configuration are cleared; no key is printed by the adapter.
This is not a comprehensive managed-memory zeroization guarantee.

CURVE encrypts/authenticates TCP sessions. ZAP binds the client's actual key to
one enrolled peer ID; unknown keys/domains and duplicate peer keys fail. Server
`ZAP_ENFORCE_DOMAIN=1` prevents libzmq's encryption-only fallback when ZAP is
unavailable. The source/routing ID in an envelope is never authentication.

Every request checks the authenticated peer's caller/destination scope and a live
application authorization callback returning exactly `T`. A separate trusted
actor-invocation carries this peer ID to `make-mesh-receiver`, which rechecks
deadline and authorization inside the actor mailbox. Application handlers must
repeat checks at later privileged effects; this transport does not implement
atomic lease fencing or grant device permissions.

All results, including delayed replies, travel over that peer's pinned outbound
DEALER, never a cached ROUTER route. This prevents another enrolled key from
claiming an old routing ID and receiving a private reply. The peer/local public
key enrollment snapshot survives stop/resume. A changed provider key fails closed;
old requests/results are not rerouted to a new principal. Live key rotation or
peer-ID reassignment is not implemented. Changing enrollment requires an explicit
fresh runtime after prior work is reconciled; process loss leaves mutations
outcome-unknown.

## Bounds and delivery semantics

Defaults: 64 KiB total encoded message, 32 client tickets/in-flight results, 32
unfinished incoming actor calls, 128 replay entries, 32 ZeroMQ HWM, 30-second
maximum absolute deadline, three attempts and one-second retry spacing. Peers and
operation lists are capped at 64. Every configured bound has a hard upper limit.
Metadata fields are ASCII, individually bounded; payload is a byte vector.
Malformed/extra frames, unknown protocol/status/required fields and oversized
messages are dropped/rejected without evaluating data or reflecting raw errors.

The wire projection has exactly 18 application frames: empty delimiter; profile
`STARROUTER/1.0/edge-private-1`; request/result kind; request ID; correlation ID;
causation ID; trace ID; asserted caller; exact destination actor; absolute Unix
millisecond deadline; content schema; operation; authorization-context reference;
idempotency-key reference; reserved empty cancellation and provenance frames;
result status (empty for request); payload bytes. A ROUTER adds its routing frame
outside this envelope. Static enrollment pins this exact profile; dynamic
negotiation, capability leases, cancellation and arbitrary metadata are not
implemented and required unsupported values fail explicitly.

- Callers supply globally unique request-attempt IDs. Requests are copied before
  queuing and retransmission. Replies must match peer and all correlation fields.
- Only locally declared read-only/retry-safe operations retry, within attempt and
  deadline limits, using identical bytes/ID. Mutations never auto-retry.
- Same peer/ID/bytes returns the cached result or waits for the original work;
  changed bytes conflict. Expired original deadlines cannot re-execute after
  replay eviction; a per-mesh clock watermark prevents backwards wall-clock corrections from reviving them. The volatile table cannot deduplicate across process restart.
- Lost/suspended mutation results, partial-send failures and ambiguous admission
  return `outcome-unknown`, not proof of non-execution. Disconnect is not rollback.
- Completed replies retry boundedly under temporary backpressure without repeating
  actor work. Authorization is checked again at each actual send; revoked private
  payloads are discarded. Exhausted reply retries can still leave outcome-unknown.
- An expired/timed-out caller does not free unfinished actor capacity. Sento asks
  do not use waiter timeouts as completion proof. Ambiguous submission/poll errors
  retain a charged unsettled slot until teardown/reconciliation. Availability can
  stop when all slots are uncertain, which is preferable to unbounded work.
- Stop does not cancel already dispatched effects. Apps needing recovery must use
  their existing durable idempotency/outbox/lease authority, not infer it from ZMQ.

Request/result printers redact payloads. Tests cover credential/handler/poll
exceptions and default Sento output with a synthetic secret marker. No marker or
raw condition is emitted in mesh wire/status paths or those captured test logs.
This does not certify arbitrary application logging, custom appenders or all
third-party diagnostics as redacted.

## Native resource containment is a separate prerequisite

libzmq 4.3.5 checks `MAXMSGSIZE` for each decoded frame, while HWM accounting
advances only after a final multipart frame. An authenticated hostile peer can
therefore cause native allocation before Lisp can check total size/frame count.
Application bounds/HWM alone do **not** solve incomplete-multipart resource DoS.
Sources: [decoder](https://github.com/zeromq/libzmq/blob/v4.3.5/src/v2_decoder.cpp#L64-L68)
and [pipe accounting](https://github.com/zeromq/libzmq/blob/v4.3.5/src/pipe.cpp#L213-L217).

The default native gate is a real read-only verifier for 64-bit **SBCL/Linux**:
`verify-linux-process-memory-limit` calls `getrlimit(RLIMIT_AS)` and requires
64 MiB <= soft <= hard <= the configured ceiling (4 GiB default, at most 16 GiB).
It also reads the kernel's aggregate `VmSize` from `/proc/self/status` and requires
current mapped virtual bytes <= hard. Lowering a limit below existing reservations
does not remove them, so finite readback alone is insufficient. Before/after limit
observations must match. No raw VMA addresses are read or logged.
It rejects root, CAP_SYS_RESOURCE in the **permitted** set even if effective is
clear, inconsistent capability masks, missing/malformed kernel fields, unlimited
limits, inspection failures and unsupported platforms. Kernel field meanings are
specified in [proc status](https://man7.org/linux/man-pages/man5/proc_pid_status.5.html).
It never sets or raises a limit. The hard
limit blocks an unprivileged process from raising the soft limit above the budget;
see [Linux resource-limit semantics](https://man7.org/linux/man-pages/man2/getrlimit.2.html).
Trusted/privileged host changes remain outside this threat boundary.

This is process address-space containment, **not** a guarantee of availability,
actor effect atomicity, or isolation from other workloads in that same process.
Resource exhaustion may terminate the runtime, leaving effects outcome-unknown.
Only an appropriately isolated deployment should use this profile. A custom
`native-budget-check` must verify an actual existing enforceable process/container
budget; a boolean preference or environment flag is not such verification.

This workspace has unlimited address space: the real default verifier rejects
it. Finite-bound test cases use a fake syscall and do not prove an enforced cap.
The parent host limits were unchanged. A later explicitly approved attempt in an
unprivileged child with finite lowered address-space limits was blocked by libzmq
interface-discovery permissions before authentication/delivery checks. No bypass
or repeat attempt was made. Native hostile multipart/limit-failure acceptance is
still unrun; see the [verification record](PRIVATE-MESH-EVIDENCE.md).

## Android is still unavailable for this transport

The composed ECL/LMDB/JNI runtime is retained. It is not an ABCL replacement.
Its current native bundle does not establish CFFI, libzmq with CURVE/libsodium,
ABI closure or an enforceable isolated-process memory budget. Source-only CFFI
on ECL additionally needs verified target `:DFFI`/libffi, or precompiled FFI code;
no on-device C compiler is assumed. The SBCL/Linux verifier explicitly returns
NIL for ECL/Android, where ART reservations make blindly applying this rule unsafe.

No Android transport dependency was installed or downloaded. Java/Kotlin do not
implement a second actor protocol. A missing optional system or explicitly enabled
mesh with unavailable native/auth/budget prerequisites fails startup. Android
local Lisp readiness remains independent. Required gates include actual ABI/DFFI
build, device owner-thread/lifecycle checks, trusted enrollment, encrypted two-peer
traffic, negative ZAP tests, memory-pressure containment, and process death/recovery.

## Reproducible verification

Dependency-free: `sbcl --script tests/mesh.lisp`.
With **already available** CFFI, Bordeaux Threads and Sento ASDF dependencies:
`tools/test_mesh.sh`. It runs synthetic semantics/ZAP/binding checks, the real
managed thread lifecycle, real local Sento actors over synthetic transport, and
captured default-log marker checks. It never installs dependencies or opens TCP.

`tests/mesh-zmq-loopback.lisp` is a separate **environment-blocked real** acceptance test. On an
authorized socket-capable SBCL/Linux host with an existing qualifying resource
budget, run `EDGE_RUN_ZMQ_LOOPBACK=1 sbcl --script tests/mesh-zmq-loopback.lisp`.
It uses in-memory ephemeral keys, fixed loopback ports 49101–49103, two enrolled
peers, real Sento roundtrips in both directions, and an unknown-key peer that must
not dispatch. No live services or external actors are contacted, and no key files
are written. Do not substitute synthetic passes for this gate.

Additional unrun hostile-wire gates: forged User-Id metadata, wrong server key,
missing/broken ZAP, stale ROUTER-ID reuse, changed-key re-enrollment, malformed and
unfinished multipart streams under memory limits, disconnect/reconnect with
in-flight mutation, and process-restart reconciliation. No performance, Android,
public-swarm, production-hardening or durable-delivery claim follows from this slice.
