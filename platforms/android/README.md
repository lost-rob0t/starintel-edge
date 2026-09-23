# Android runtime host

`EdgeHost.kt` is a compilable, typed facade for the shared Common Lisp port. It deliberately reports unavailable until a backend is injected. It is not yet a Service, APK, ABCL loader, or working local runtime.

Required implementation: Android library/AAR with verified ABCL integration, a diagnostic host APK, platform lifecycle adapter, app-private durable outbox, local/offline mode and explicit optional relay. Kotlin/Java must not reimplement actor semantics or the StarLang compiler. Existing Android field-client and Zara UIs consume this library; their product UX need not move here.

Acceptance: real Android ART loading and Lisp execution, start/stop/process death, offline restart, permission revocation, foreground/while-in-use restrictions, bounded queues, local-to-remote status clarity and no mandatory cloud account for the local path. Desktop JVM success is not evidence of Android ABCL compatibility.

Reference: https://developer.android.com/develop/background-work/services/fgs/restrictions-bg-start (checked 2026-09-23).
