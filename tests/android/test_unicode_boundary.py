"""Production scalar codec and JNI transport tests; neither loads ECL or ART."""
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


def compiler():
    return shlex.split(os.environ.get("CC", "cc")) + ["-std=c99", "-Wall", "-Wextra", "-Werror", "-pedantic", "-Iplatforms/android/native"]


class UnicodeBoundary(unittest.TestCase):
    def test_exhaustive_scalar_codec(self):
        with tempfile.TemporaryDirectory(prefix="edge-unicode-") as tmp:
            binary = Path(tmp) / "utf_test"
            subprocess.run(compiler() + shlex.split(os.environ.get("PARSER_TEST_CFLAGS", "")) +
                           ["tests/android/utf_test.c", "-o", str(binary)], cwd=ROOT, check=True)
            subprocess.run([str(binary)], check=True)

    def test_host_jni_transport(self):
        java = shutil.which("java")
        if not java:
            self.skipTest("Existing host JDK required; this test never downloads one")
        java_home = Path(os.environ.get("JAVA_HOME", str(Path(java).resolve().parents[1])))
        include = Path(os.environ.get("JNI_INCLUDE_DIR", str(java_home / "include")))
        if not (include / "jni.h").is_file():
            self.skipTest("Existing JNI headers required; set JNI_INCLUDE_DIR (no downloads)")
        with tempfile.TemporaryDirectory(prefix="edge-jni-test-") as tmp:
            library = Path(tmp) / "libedge_jni_transport.so"
            subprocess.run(compiler() + ["-fPIC", "-shared", "-I" + str(include),
                           "-I" + str(include / "linux"), "platforms/android/native/starintel_ecl_jni.c",
                           "tests/android/jni_transport_stub.c", "-o", str(library)], cwd=ROOT, check=True)
            subprocess.run([java, "com.sun.tools.javac.Main", "-encoding", "UTF-8", "-source", "17", "-target", "17",
                           "-d", tmp, "tests/android/jni/StarIntelEdgeRuntime.java"], cwd=ROOT, check=True)
            subprocess.run([java, "-Xcheck:jni", "-cp", tmp, "actor.starintel.edge.StarIntelEdgeRuntime", str(library)],
                           cwd=ROOT, check=True)


if __name__ == "__main__":
    unittest.main()
