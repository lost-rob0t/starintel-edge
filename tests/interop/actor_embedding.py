#!/usr/bin/env python3
"""Host fenv repair and safe managed-unavailability regression; no installs.

Fenv diagnostic directly exercises the standalone C ABI from an isolated JVM
process. It does NOT admit production managed embedding. Production Kotlin/JNI
must decline before ECL boot, checked and unchecked. ART is not executed here.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
NATIVE = ROOT / "platforms/android/native"
TEST = ROOT / "tests/interop"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", type=Path)
    args = parser.parse_args()
    out = (args.output_dir or Path(tempfile.mkdtemp(prefix="edge-embedding-regression-"))).resolve()
    out.mkdir(parents=True, exist_ok=True)
    (out / "summary.json").write_text('{"status":"running"}\n')
    env = os.environ.copy()
    prefix = Path(env["ECL_PREFIX"]).resolve()
    env["ECLDIR"] = str(next((prefix / "lib").glob("ecl-*/"))) + "/"
    env["LD_LIBRARY_PATH"] = str(prefix / "lib") + ":" + env.get("LD_LIBRARY_PATH", "")
    env["LIBRARY_PATH"] = str(prefix / "lib") + ":" + env.get("LIBRARY_PATH", "")
    env["C_INCLUDE_PATH"] = str(prefix / "include") + ":" + env.get("C_INCLUDE_PATH", "")
    env["EDGE_ACTOR_INTEROP_ROOT"] = str(ROOT)
    jni = Path(env["JNI_INCLUDE_DIR"]).resolve()
    stdlib = Path(env["KOTLIN_STDLIB"]).resolve()
    lmdb = Path(env["LMDB_LIBRARY"]).resolve()
    java = shlex.split(env.get("JAVA", "java"))
    cc = shlex.split(env.get("CC", "cc")) + ["-std=gnu99", "-O2", "-Wall", "-Wextra", "-Werror", "-fPIC", "-shared",
            "-I" + str(NATIVE), "-isystem", str(prefix / "include")]
    sources = sorted(NATIVE.glob("*.[ch]")) + [TEST / "actor_embedding.py", TEST / "actor_embedding_probe.c",
        TEST / "actor_embedding_fixture.lisp", TEST / "actor/ActorEmbeddingProbe.java", TEST / "actor/ActorManagedUnavailable.java",
        TEST / "actor/startup.lisp", ROOT / "platforms/android/kotlin/actor/starintel/edge/StarIntelEdgeRuntime.kt",
        ROOT / "tools/host-lisp-sources.json"] + sorted((ROOT / "runtime").glob("*.lisp")) + sorted((ROOT / "runtime").glob("*.asd"))
    def hashes():
        return {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sources}
    before = hashes()
    results, logs = [], []
    toolchains = {}
    def run(command, data=None):
        log = out / ("%02d.log" % (len(logs) + 1))
        process = subprocess.run(command, cwd=ROOT, env=env, input=data, stdout=subprocess.PIPE,
                                 stderr=subprocess.STDOUT, timeout=300)
        log.write_bytes(process.stdout)
        logs.append(log.name)
        if process.returncode:
            raise RuntimeError("Failed command; see %s:\n%s" % (log, process.stdout[-10000:].decode("utf-8", "replace")))
        return process.stdout.decode("utf-8", "strict")
    def ensure(value, detail):
        if not value: raise RuntimeError(detail)
    try:
        toolchains["java"] = run(java + ["-version"]).strip()
        toolchains["cc"] = run(shlex.split(env.get("CC", "cc")) + ["--version"]).splitlines()[0]
        toolchains["ecl_library_sha256"] = hashlib.sha256((prefix / "lib/libecl.so").read_bytes()).hexdigest()
        toolchains["kotlin_stdlib_sha256"] = hashlib.sha256(stdlib.read_bytes()).hexdigest()
        run(cc + [str(NATIVE / "starintel_ecl_adapter.c"), "-L" + str(prefix / "lib"),
                  "-Wl,-rpath," + str(prefix / "lib"), "-lecl", "-lm", "-o", str(out / "libstarintel_ecl_adapter.so")])
        run(cc + ["-I" + str(jni), "-I" + str(jni / "linux"), str(NATIVE / "starintel_ecl_jni.c"),
                  "-L" + str(out), "-Wl,-rpath," + str(out), "-lstarintel_ecl_adapter", "-o", str(out / "libstarintel_ecl_jni.so")])
        run(cc + ["-I" + str(jni), "-I" + str(jni / "linux"), str(TEST / "actor_embedding_probe.c"),
                  "-L" + str(out), "-Wl,-rpath," + str(out), "-lstarintel_ecl_adapter",
                  "-L" + str(prefix / "lib"), "-lecl", "-lm", "-o", str(out / "libfenvprobe.so")])
        for name, target in (("libecl.so", prefix / "lib/libecl.so"), ("liblmdb.so", lmdb)):
            destination = out / name
            if destination.exists() or destination.is_symlink():
                ensure(destination.resolve() == target.resolve(), "Existing library target differs")
            else: destination.symlink_to(target)
        classes = out / "classes"
        classes.mkdir(exist_ok=True)
        run(shlex.split(env.get("KOTLINC", "kotlinc")) + ["-no-stdlib", "-no-reflect", "-classpath", str(stdlib),
            "-jvm-target", "17", "-d", str(classes), str(ROOT / "platforms/android/kotlin/actor/starintel/edge/StarIntelEdgeRuntime.kt")])
        classpath = str(classes) + os.pathsep + str(stdlib)
        run(java + ["com.sun.tools.javac.Main", "-encoding", "UTF-8", "-cp", classpath, "-d", str(classes),
                    str(TEST / "actor/ActorEmbeddingProbe.java"), str(TEST / "actor/ActorManagedUnavailable.java")])
        runtime = out / "runtime"
        failed = out / "failed-runtime"
        for directory in (runtime, failed): (directory / "lisp").mkdir(parents=True, exist_ok=True)
        shutil.copyfile(TEST / "actor_embedding_fixture.lisp", runtime / "lisp/startup.lisp")
        (failed / "lisp/startup.lisp").write_text('(error "trusted startup failure")\n')
        for checked in (True, False):
            vm = java + (["-Xcheck:jni"] if checked else []) + ["-Djava.library.path=" + str(out), "-cp", classpath]
            for failed_boot in (False, True):
                env["EDGE_PROBE_RUNTIME"] = str(failed if failed_boot else runtime)
                output = run(vm + ["ActorEmbeddingProbe", str(out / "libfenvprobe.so"), str(failed_boot).lower()])
                count = 16 if failed_boot else 30
                ensure("ACTOR_FENV\tpassed:%d" % count in output, "fenv completion missing")
                ensure("MXCSR changed" not in output and "FENV FAIL" not in output, "fenv leak detected")
                results.append({"scope": "standalone C ABI fenv diagnostic, not managed runtime acceptance",
                                "checked_jni": checked, "failed_boot": failed_boot, "checks": count, "status": "passed"})
            env["EDGE_PROBE_RUNTIME"] = str(runtime)
            output = run(vm + ["ActorManagedUnavailable", str(out / "libfenvprobe.so"), str(runtime)])
            ensure("ACTOR_MANAGED_GATE\tpassed:" in output and ";production-jni:9" in output, "managed gate incomplete")
            ensure("handler modified" not in output and "MXCSR changed" not in output and "FENV FAIL" not in output,
                   "unavailable managed gate changed runtime state")
            results.append({"scope": "production Kotlin/JNI managed start is safely unavailable before ECL boot",
                            "checked_jni": checked, "status": "passed"})
        ensure(hashes() == before, "Sources changed during regression")
        summary = {"status": "passed", "managed_runtime": "unavailable-unverified-embedding", "source_sha256": before,
                   "results": results, "logs": logs, "art_tested": False, "toolchains": toolchains}
        (out / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
        print(json.dumps(summary, indent=2))
        print("Embedding regression evidence:", out)
    except Exception as error:
        (out / "summary.json").write_text(json.dumps({"status": "failed", "results": results, "error": str(error), "logs": logs}, indent=2) + "\n")
        print("Embedding regression evidence:", out)
        raise


if __name__ == "__main__": main()
