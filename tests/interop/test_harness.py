"""Guards against false-positive matrix comparisons."""
import unittest
from test_documents import equivalent, pack, unpack, numeric_equivalent, unpack_numbers, normalized_number, load_fixture, fixture_encode
class HarnessTests(unittest.TestCase):
    def test_false_is_not_zero(self):
        self.assertFalse(equivalent({'flag': False}, {'flag': 0}))
    def test_absence_is_not_null(self):
        self.assertFalse(equivalent({}, {'field': None}))
    def test_numeric_precision(self):
        self.assertFalse(equivalent(9007199254740993,9007199254740992))
    def test_exact_numeric_comparison(self):
        self.assertTrue(numeric_equivalent(unpack_numbers(b"1.0\n"), unpack_numbers(b"1\n")))
        self.assertFalse(numeric_equivalent(unpack_numbers(b"1.0000000000000000000001\n"), unpack_numbers(b"1\n")))
        self.assertFalse(numeric_equivalent(False, 0))

    def test_symbolic_exponent_oracle(self):
        self.assertEqual(normalized_number("100e999999999999999999999"), normalized_number("1e1000000000000000000001"))
        self.assertEqual(normalized_number("-0e-999999999999999999999"), normalized_number("0"))
        self.assertNotEqual(normalized_number("1e999999999999999999999"), normalized_number("1e999999999999999999998"))

    def test_lossless_fixture_tokens(self):
        original='{"n":1e999999999999999999999,"tiny":0.12345678901234567890123456789,"string":"1e9","flag":false}'
        self.assertEqual(fixture_encode(load_fixture(original)), original)
        token='1e'+'9'*5000
        self.assertEqual(normalized_number(token), normalized_number('10e'+'9'*4999+'8'))

    def test_lengths(self):
        self.assertFalse(equivalent([1],[1,2]))
    def test_unicode_nul_exact_roundtrip(self):
        value=[{'text':'\x00🛰️中文','false':False,'null':None,'n':9223372036854775807}]
        self.assertTrue(equivalent(value,unpack(pack(value))))

class AdapterFailureTests(unittest.TestCase):
    def test_python_programming_failure_is_not_rejection(self):
        import os, pathlib, subprocess, sys, tempfile
        with tempfile.TemporaryDirectory() as temp:
            root = pathlib.Path(temp)
            package = root / 'starintel_canonical'
            package.mkdir()
            (package / '__init__.py').write_text('import json\nparse_json=json.loads\nstringify_json=json.dumps\ndef roundtrip_document(value): raise RuntimeError("injected SDK failure")\n')
            (package / 'errors.py').write_text('class ValidationError(ValueError): pass\n')
            env = dict(os.environ, INTEROP_PYTHON_SDK=temp)
            p = subprocess.run([sys.executable, str(pathlib.Path(__file__).with_name('document_python.py')), 'reject'],
                               input='{}\n', text=True, capture_output=True, env=env)
            self.assertNotEqual(p.returncode, 0)
            self.assertIn('injected SDK failure', p.stderr)
            self.assertEqual(p.stdout, '')

    def test_optimized_orchestrator_fails_closed(self):
        import pathlib, subprocess, sys
        p = subprocess.run([sys.executable, '-O', str(pathlib.Path(__file__).with_name('test_documents.py'))],
                           text=True, capture_output=True)
        self.assertNotEqual(p.returncode, 0)
        self.assertIn('require Python assertions enabled', p.stderr)

if __name__=='__main__': unittest.main()
