#!/usr/bin/env python3
"""Host-only real actor binding gate; no downloads, listeners, stubs or ART claims.

Full mode executes C, Kotlin and Java through production ECL/JNI plus SBCL.
Missing prerequisites are failures, never successful skips. See INTEROP-ACTOR.md.
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
FIXTURE = Path(__file__).with_name("actor")
NATIVE = ROOT / "platforms/android/native"


def corpus(document_payloads=()):
    cases = []
    for text in ("", "ASCII", "café", "中文", "🙂𝄞", "e\u0301", "é", 'quote"slash\\line\n',
                 "before\0after", '#.(error "must stay opaque")', "reply-A-🙂", "reply-B-中文", "reply-A-🙂") + tuple(document_payloads):
        cases.append(({"op": "dispatch", "payload": text, "capability": "interop.echo"},
                      {"status": "ok", "payload": text, "capability": "interop.echo", "length": len(text),
                       "codes": list(map(ord, text)), "sequence": len(cases) + 1}))
    deliveries = len(cases)
    for request, expected in [
        ({"op": "runtime.ping"}, {"status": "ok", "runtime": "starintel-edge", "adapter-abi": 1, "platform": "android"}),
        ({"op": "actor.roundtrip"}, {"status": "ok", "actor": "roundtrip", "message": "android-local"}),
        ({"op": "dispatch", "payload": "forbidden", "capability": "camera.photo"},
         {"status": "denied", "reason": "capability-not-authorized"}),
        ({"op": "dispatch", "payload": "forbidden", "capability": "interop.echo\0suffix"},
         {"status": "denied", "reason": "capability-not-authorized"}),
        ({"op": "dispatch", "payload": "forbidden"}, {"status": "denied", "reason": "capability-not-authorized"}),
        ({"op": "eval", "payload": '(error "must not execute")'}, {"status": "error", "reason": "unknown-operation"}),
        ({"op": "runtime.ping\0suffix"}, {"status": "error", "reason": "unknown-operation"}),
        ({"op": "service.stop\0suffix"}, {"status": "error", "reason": "unknown-operation"}),
        ({"op": "status"}, {"status": "ok", "actor-deliveries": deliveries}),
    ]:
        cases.append((request, expected))
    return cases


def malformed():
    return [
        b'{"op":"runtime.ping","version":2}',
        b'{"op":"runtime.ping","correlation":"unsupported"}',
        b'{"op":"runtime.ping","op":"service.stop"}',
        b'{"op":"runtime.ping"} trailing',
        b'{"op":"dispatch","payload":"\\ud800","capability":"interop.echo"}',
        b'{"op":"dispatch","payload":"\\udc00","capability":"interop.echo"}',
        b'{"op":"dispatch","payload":"\xc0\x80","capability":"interop.echo"}',
        b'{"op":"dispatch","payload":"\xed\xa0\x80","capability":"interop.echo"}',
        b'{"op":"dispatch","payload":"\xf4\x90\x80\x80","capability":"interop.echo"}',
    ]


def lisp_string(value):
    # This is a trusted test program generated from the local corpus, not a wire reader.
    return "(map 'string #'code-char '(%s))" % " ".join(map(str, map(ord, value)))


def ensure(condition, detail):
    if not condition:
        raise RuntimeError(str(detail))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mode", choices=("lisp", "native", "full"), default="full")
    parser.add_argument("--document-corpus", action="append", default=[], metavar="LANGUAGE=NDJSON",
                        help="Echo exact producer-emitted canonical message/person records as opaque actor payloads")
    parser.add_argument("--output-dir", type=Path, help="Preserve logs and summary outside the source tree")
    args = parser.parse_args()
    out = args.output_dir or Path(tempfile.mkdtemp(prefix="edge-actor-interop-"))
    out = out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    (out / "summary.json").write_text(json.dumps({"status": "running", "mode": args.mode}) + "\n", encoding="utf-8")
    env = os.environ.copy()
    env["EDGE_ACTOR_INTEROP_ROOT"] = str(ROOT)
    env["XDG_CACHE_HOME"] = str(out / "cache")
    results = []
    toolchains = {}
    command_logs = []
    command_index = 0
    production = sorted((ROOT / "runtime").glob("*.lisp")) + sorted((ROOT / "runtime").glob("*.asd")) + sorted(NATIVE.glob("*.[ch]")) + [
        ROOT / "platforms/android/kotlin/actor/starintel/edge/StarIntelEdgeRuntime.kt",
        ROOT / "tools/host-lisp-sources.json"]
    harness = sorted(FIXTURE.glob("*")) + [Path(__file__).resolve(), ROOT / "tests/interop/actor_mesh.lisp"]
    def hashes(paths):
        return {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest() for path in paths}
    initial_hashes = hashes(production)
    initial_harness = hashes(harness)
    document_sources = {}
    document_payloads = []
    for spec in args.document_corpus:
        language, separator, filename = spec.partition("=")
        ensure(separator and language and language not in document_sources, "Use unique LANGUAGE=NDJSON arguments")
        path = Path(filename).resolve()
        raw = path.read_bytes()
        selected = {}
        for line in raw.decode("utf-8", "strict").splitlines():
            record = json.loads(line)
            if record.get("dtype") in ("person", "message") and record.get("schemaVersion") == "0.10.1":
                selected.setdefault(record["dtype"], line)
        ensure(set(selected) == {"person", "message"}, "Canonical person/message missing from " + language)
        document_payloads.extend(selected[kind] for kind in ("person", "message"))
        document_sources[language] = {"path": str(path), "sha256": hashlib.sha256(raw).hexdigest(),
                                      "records": ["person", "message"]}

    def decode_response(line):
        def pairs(items):
            values = {}
            for key, value in items:
                ensure(key not in values, "Duplicate response key: " + key)
                values[key] = value
            return values
        return json.loads(line, object_pairs_hook=pairs,
                          parse_constant=lambda value: (_ for _ in ()).throw(ValueError(value)))

    def run(command, *, data=None):
        nonlocal command_index
        command_index += 1
        log = out / ("%02d.log" % command_index)
        completed = subprocess.run(command, cwd=ROOT, env=env, input=data, stdout=subprocess.PIPE,
                                   stderr=subprocess.STDOUT, timeout=300)
        log.write_bytes(completed.stdout)
        command_logs.append({"log": log.name, "returncode": completed.returncode})
        if completed.returncode:
            raise RuntimeError("command failed (%s), log %s:\n%s" %
                               (completed.returncode, log, completed.stdout[-12000:].decode("utf-8", "replace")))
        return completed.stdout.decode("utf-8", "strict")

    def verify(name, output, expected, *, abi=False, native_checks=None):
        actual = [decode_response(line.split("\t", 1)[1]) for line in output.splitlines()
                  if line.startswith("ACTOR_RESULT\t")]
        ensure(json.dumps(actual, sort_keys=True) == json.dumps(expected, sort_keys=True), (name, actual, expected))
        if abi:
            ensure("ACTOR_ABI\t1" in output.splitlines(), name)
        if native_checks is not None:
            ensure("ACTOR_CLIENT_CHECKS\t%d" % native_checks in output.splitlines(), name)
        ensure("WARNING in native method" not in output and "FATAL ERROR in native method" not in output,
               "JNI usage violation detected for " + name)
        runtime_warnings = [line for line in output.splitlines()
                            if (line.startswith("Warning: SIG") and "handler modified" in line)
                            or ("MXCSR changed by native JNI code" in line)]
        runtime_versions = [decode_response(line.split("\t", 1)[1]) for line in output.splitlines()
                            if line.startswith("ACTOR_RUNTIME\t")]
        ensure(len(runtime_versions) == 1, "Runtime/dependency version marker missing for " + name)
        result = {"path": name, "status": "passed_with_runtime_warnings" if runtime_warnings else "passed", "responses": len(actual),
                  "extra_client_checks": native_checks or 0,
                  "runtime": runtime_versions, "runtime_warnings": sorted(set(runtime_warnings))}
        results.append(result)
        print(json.dumps(result), flush=True)

    try:
        cases = corpus(document_payloads)
        sbcl = shlex.split(env.get("SBCL", "sbcl"))
        toolchains["sbcl"] = run(sbcl + ["--version"]).strip()
        driver = out / "actor-direct.lisp"
        driver.write_text('(load "%s")\n' % (FIXTURE / "startup.lisp") +
                          "\n".join('(format t "ACTOR_RESULT~C~A~%%" #\\Tab (star.edge.android:handle-request %s %s %s))' %
                                    tuple(lisp_string(request[key]) if key in request else "nil"
                                          for key in ("op", "payload", "capability"))
                                    for request, _ in cases) +
                          "\n(assert (star.edge.android:stop-service-runtime))\n", encoding="utf-8")
        verify("Common Lisp/SBCL → real Sento → Common Lisp", run(sbcl + ["--script", str(driver)]),
               [expected for _, expected in cases])
        mesh_output = run(sbcl + ["--script", str(ROOT / "tests/interop/actor_mesh.lisp")])
        mesh_counts = [int(line.split("\t", 1)[1]) for line in mesh_output.splitlines()
                       if line.startswith("ACTOR_MESH_CHECKS\t")]
        ensure(len(mesh_counts) == 1 and mesh_counts[0] > 0, "mesh completion marker missing")
        results.append({"path": "Common Lisp real Sento actors over synthetic mesh transport",
                        "status": "passed", "checks": mesh_counts[0], "network": False})
        print(json.dumps(results[-1]), flush=True)
        if args.mode != "lisp":
            prefix = env.get("ECL_PREFIX")
            if prefix:
                prefix = Path(prefix).resolve()
                cflags = ["-I" + str(prefix / "include")]
                libs = ["-L" + str(prefix / "lib"), "-Wl,-rpath," + str(prefix / "lib"), "-lecl", "-lm"]
                runtimes = sorted((prefix / "lib").glob("ecl-*"))
                if runtimes:
                    env.setdefault("ECLDIR", str(runtimes[-1]) + "/")
                env["C_INCLUDE_PATH"] = str(prefix / "include") + ":" + env.get("C_INCLUDE_PATH", "")
                env["LIBRARY_PATH"] = str(prefix / "lib") + ":" + env.get("LIBRARY_PATH", "")
                env["LD_LIBRARY_PATH"] = str(prefix / "lib") + ":" + env.get("LD_LIBRARY_PATH", "")
            else:
                config = shlex.split(env.get("ECL_CONFIG", "ecl-config"))
                cflags = shlex.split(run(config + ["--cflags"]).strip())
                libs = shlex.split(run(config + ["--libs"]).strip())
            cflags = shlex.split(env.get("ECL_CFLAGS", "")) or cflags
            libs = shlex.split(env.get("ECL_LIBS", "")) or libs
            cc = shlex.split(env.get("CC", "cc")) + ["-std=gnu99", "-O2", "-Wall", "-Wextra", "-Werror", "-I" + str(NATIVE)]
            toolchains["cc"] = run(shlex.split(env.get("CC", "cc")) + ["--version"]).splitlines()[0]
            native = out / "actor-native"
            run(cc + cflags + [str(FIXTURE / "client.c"), str(NATIVE / "starintel_ecl_adapter.c"),
                               "-o", str(native)] + libs)
            runtime = out / "runtime-café-🙂"
            (runtime / "lisp").mkdir(parents=True, exist_ok=True)
            shutil.copyfile(FIXTURE / "startup.lisp", runtime / "lisp/startup.lisp")
            for escaped in (False, True):
                data = [json.dumps(request, ensure_ascii=escaped).encode("utf-8") for request, _ in cases]
                # Invalid UTF-8 must go directly to C. A Java text reader would replace it.
                data += malformed() + [b'{"op":"status"}']
                expected = [expected for _, expected in cases] + [
                    {"status": "error", "reason": "malformed-request"} for _ in malformed()] + [cases[-1][1]]
                verify("C → production C ABI/ECL → real Sento → C (%s JSON)" % ("escaped" if escaped else "raw"),
                       run([str(native), str(runtime)], data=b"\n".join(data) + b"\n"), expected,
                       abi=True, native_checks=2)
            if args.mode == "full":
                java = shlex.split(env.get("JAVA", "java"))
                java_home = Path(env.get("JAVA_HOME", str(Path(shutil.which(java[0])).resolve().parents[1])))
                jni = Path(env.get("JNI_INCLUDE_DIR", str(java_home / "include")))
                stdlib = Path(env["KOTLIN_STDLIB"]).resolve()
                lmdb = Path(env["LMDB_LIBRARY"]).resolve()
                ensure(stdlib.is_file() and lmdb.is_file() and (jni / "jni.h").is_file(), "existing JVM prerequisites required")
                toolchains["java"] = run(java + ["-version"]).strip()
                toolchains["kotlin"] = run(shlex.split(env.get("KOTLINC", "kotlinc")) + ["-version"]).strip()
                toolchains["kotlin_stdlib_sha256"] = hashlib.sha256(stdlib.read_bytes()).hexdigest()
                toolchains["lmdb_sha256"] = hashlib.sha256(lmdb.read_bytes()).hexdigest()
                libdir = out / "lib"
                libdir.mkdir(exist_ok=True)
                def link_library(name, target):
                    destination = libdir / name
                    if destination.exists() or destination.is_symlink():
                        ensure(destination.resolve() == target.resolve(), "Existing output library has a different target")
                    else:
                        destination.symlink_to(target)
                # Reuse actual existing libraries. No stub can satisfy these loads.
                if prefix:
                    link_library("libecl.so", prefix / "lib/libecl.so")
                else:
                    ecl_library = Path(env["ECL_LIBRARY"]).resolve()
                    link_library("libecl.so", ecl_library)
                link_library("liblmdb.so", lmdb)
                run(cc + cflags + ["-fPIC", "-shared", str(NATIVE / "starintel_ecl_adapter.c"),
                                   "-o", str(libdir / "libstarintel_ecl_adapter.so")] + libs)
                run(cc + ["-fPIC", "-shared", "-I" + str(jni), "-I" + str(jni / "linux"),
                          str(NATIVE / "starintel_ecl_jni.c"), "-L" + str(libdir),
                          "-Wl,-rpath," + str(libdir), "-lstarintel_ecl_adapter",
                          "-o", str(libdir / "libstarintel_ecl_jni.so")])
                classes = out / "classes"
                classes.mkdir(exist_ok=True)
                run(shlex.split(env.get("KOTLINC", "kotlinc")) + ["-no-stdlib", "-no-reflect", "-classpath", str(stdlib),
                     "-jvm-target", "17", "-d", str(classes),
                     str(ROOT / "platforms/android/kotlin/actor/starintel/edge/StarIntelEdgeRuntime.kt"),
                     str(FIXTURE / "KotlinActorClient.kt")])
                classpath = str(classes) + os.pathsep + str(stdlib)
                run(java + ["com.sun.tools.javac.Main", "-encoding", "UTF-8", "-source", "17", "-target", "17",
                            "-cp", classpath, "-d", str(classes), str(FIXTURE / "JavaActorClient.java")])
                for language in ("Java", "Kotlin"):
                    for escaped in (False, True):
                        data = [json.dumps(request, ensure_ascii=escaped).encode("utf-8") for request, _ in cases]
                        # JSON syntax negatives are valid UTF-8 and must survive the JVM boundary.
                        data += malformed()[:6] + [b'{"op":"status"}']
                        expected = [expected for _, expected in cases] + [
                            {"status": "error", "reason": "malformed-request"} for _ in malformed()[:6]] + [cases[-1][1]]
                        verify("%s → production Kotlin/JNI/C/ECL → real Sento → %s (%s JSON)" %
                               (language, language, "escaped" if escaped else "raw"),
                               run(java + ["-Xcheck:jni", "-Djava.library.path=" + str(libdir), "-cp", classpath,
                                   "actor.interop." + language + "ActorClient", str(runtime)], data=b"\n".join(data) + b"\n"),
                               expected, abi=True, native_checks=6)
        ensure(hashes(production) == initial_hashes, "Production sources changed during the run")
        ensure(hashes(harness) == initial_harness, "Test harness changed during the run")
        for source in document_sources.values():
            ensure(hashlib.sha256(Path(source["path"]).read_bytes()).hexdigest() == source["sha256"],
                   "Producer corpus changed during the run")
        summary = {"production_sha256": initial_hashes, "harness_sha256": initial_harness,
                   "document_sources": document_sources, "toolchains": toolchains, "command_logs": command_logs, "scope": "host-only real actor adapters; no ART/device/network evidence", "mode": args.mode,
                   "paths": results, "status": "passed_with_runtime_warnings" if any(path.get("runtime_warnings") for path in results) else "passed",
                   "runtime_safety_gate": "not-established", "source_revision":
                   subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()}
        (out / "summary.json").write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
        print("Actor adapter functional integration:", summary["status"], "; evidence:", out / "summary.json")
    except Exception as error:
        (out / "summary.json").write_text(json.dumps({"status": "failed", "mode": args.mode,
                            "paths": results, "error": str(error)}, indent=2) + "\n", encoding="utf-8")
        raise


if __name__ == "__main__":
    main()
