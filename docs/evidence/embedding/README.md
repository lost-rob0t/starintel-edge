# Embedding evidence

This directory distinguishes reproduced unsafe coexistence from the repaired
floating-point boundary and intentional managed-start unavailability.

- `baseline-fenv-and-handlers.log.gz`: original C adapter, before repair; native
  snapshots expose FP and process-handler changes before HotSpot can repair them.
- `signal-failures.json` and `reproduced-*.log.gz`: exact final probe source hashes,
  ECL library hash, JVM version, bounded outcomes and no-ECL controls. Both unsafe
  cases hit a 10-second child timeout. These are failure characterizations, not
  passing runtime gates.
- `managed-concurrent.log.gz`: narrower successful Java/Lisp condition/GC behavior;
  it does not override the failing signal and shutdown scenarios.
- `admission-*.log.gz`: active vs late-loaded libjsig registration. Registration is
  necessary but insufficient for safe embedding.
- `fenv-regression/summary.json`: repaired native and regression source hashes,
  checked/unchecked results and toolchain identities. Logs 08/09 and 11/12 are
  normal/failed-boot standalone-C diagnostics in checked/unchecked JVM processes.
  Logs 10/13 verify actual production Kotlin/JNI refuses managed startup before
  ECL boot in both VM modes; signal handlers stay unchanged. Native gate checks
  run twice per process (26 each), plus nine production-JNI assertions.

The signal probe source files are diagnostic artifacts using trusted fixed Lisp
forms, not production eval endpoints. They use the supported HotSpot chaining
mechanism and an explicit terminal-interrupt ownership experiment; no fault,
FPE, thread-interrupt or VM guard is disabled. They do not authorize using the
standalone C entry to evade the managed-start safety gate.

Previously published APKs predate this guard and are not runtime-ready. No new
APK or remote publication belongs to this repair. ART/device execution remains
unverified. See ../../EMBEDDING-SAFETY.md for the bounded next repair.

`standalone-native/summary.json` records the repaired-source standalone C/SBCL
actor run: 86 exact responses, four C lifecycle checks and 135 synthetic-mesh
checks. Managed startup is not exercised as a success path in that gate.

Log snapshots use lossless deterministic gzip. Summary log identifiers retain
the generator's original uncompressed filenames; append `.gz` to open their
checked-in snapshots with `gzip -dc`. Signal-scenario SHA-256 values cover the
decompressed bytes. `SHA256SUMS` covers the physical checked-in files.
