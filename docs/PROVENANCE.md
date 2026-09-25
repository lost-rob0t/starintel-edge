# Runtime provenance

The reusable Edge runtime is licensed GPL-3.0-or-later. Its actor routing and
lifecycle behavior adapt the corresponding Common Lisp implementation from
`starintel-server` commit `f8e20c0b5629a34580c937a5e9ec56834e324802`, whose
source headers identify Copyright (C) 2024 nsaspy.

Adapted source boundaries:

- `source/actors.lisp` informed `runtime/actors.lisp`.
- The `star.runtime` layer of `source/runtime-lifecycle.lisp` informed
  `runtime/lifecycle.lisp`.
- `t/runtime-lifecycle-test.lisp` and `t/target-routing-test.lisp` informed the
  corresponding behavior checks in `tests/runtime.lisp`.

Server-only CouchDB, RabbitMQ, HTTP, authentication, and lease-store code was
not copied. The file outbox, power policy, and Linux host adapter are Edge-owned
implementations. Downstream applications consume this repository; they do not
fork the shared runtime semantics.
