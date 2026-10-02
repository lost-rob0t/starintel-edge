# Offline durable outbox

The edge runtime owns a small platform-neutral durable outbox for outbound StarIntel
records. It is intentionally not a broker, actor engine, or sync protocol. Linux,
Android, watch, and glasses hosts may use the same queue semantics while platform
adapters choose an app-private storage path and the transport that eventually sends
an item.

## Contract

- `id` is an idempotency key supplied by the caller.
- `route` is a logical typed destination such as a STAR URI or sync channel.
- `payload` is an opaque serialized string. The outbox never reads or evaluates it.
- enqueue is FIFO and duplicate IDs are ignored.
- acknowledgement removes an item only after the remote side has accepted it.
- retry increments the attempt count and persists an explicit next-eligible time.
- count and UTF-8 string-byte budgets are checked before persistence.
- malformed state fails closed. It is never converted into an empty successful queue.
- observability exposes counts/bytes only; it does not log payloads or routes.

The implementation assumes one serialized process owns a queue file, matching the
existing host contract. Cross-process locking, distributed leases, transport ACK
semantics, encryption-at-rest, server reconciliation, and explicit fsync/power-loss
guarantees are later layers rather than hidden behavior in this primitive.

## Reproducible checks

From the repository root:

```sh
python3 tools/check_contracts.py
sbcl --script tests/runtime.lisp
sbcl --script tests/outbox.lisp
mkdir -p build
kotlinc platforms/android/EdgeHost.kt \
  platforms/watch/WatchHost.kt \
  platforms/glasses/GlassesHosts.kt \
  tests/HostContractTest.kt \
  -include-runtime -d build/host-tests.jar
java -jar build/host-tests.jar
```

For the Nix contract package, evaluate/build it with the downstream's pinned
`nixpkgs`; `platforms/rpi/default.nix` runs the Python and Common Lisp checks.
A successful host build is not Raspberry Pi boot evidence and is not Android ART
or physical-device evidence.
