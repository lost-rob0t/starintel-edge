"""Compile/run the actual C envelope parser; no ECL or Android claims."""
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class EnvelopeParserOwnership(unittest.TestCase):
    def test_malformed_envelope_cleanup(self):
        with tempfile.TemporaryDirectory(prefix="edge-parser-test-") as directory:
            binary = Path(directory) / "parse_envelope_test"
            command = shlex.split(os.environ.get("CC", "cc"))
            command += ["-std=c99", "-Wall", "-Wextra", "-Werror", "-pedantic"]
            command += shlex.split(os.environ.get("PARSER_TEST_CFLAGS", ""))
            command += ["-Iplatforms/android/native", "tests/android/parse_envelope_test.c", "-o", str(binary)]
            subprocess.run(command, cwd=ROOT, check=True)
            subprocess.run([str(binary)], cwd=ROOT, check=True)


if __name__ == "__main__":
    unittest.main()
