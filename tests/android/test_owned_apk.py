"""APK verifier tests with synthetic ELF bytes; NOT Android build/execution proof."""
import hashlib
import importlib.util
import json
from pathlib import Path
import struct
import tempfile
import unittest
import zipfile

spec = importlib.util.spec_from_file_location('verify_owned_apk', Path(__file__).with_name('verify_owned_apk.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class PackageProof(unittest.TestCase):
    def test_exact_bytes_and_elf_constraints(self):
        for fault in (None, 'stale', 'machine', 'alignment', 'entry', 'interpreter', 'missing'):
            with self.subTest(fault=fault), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                (root / 'assets').mkdir()
                (root / 'assets' / 'synthetic.lisp').write_text('; synthetic fixture\n')
                data = bytearray(176)
                data[:6] = b'\x7fELF\x02\x01'
                struct.pack_into('<HH', data, 16, 3, 183 if fault == 'machine' else 62)
                struct.pack_into('<Q', data, 24, 0 if fault == 'entry' else 4096)
                struct.pack_into('<Q', data, 32, 64)
                struct.pack_into('<HH', data, 54, 56, 2)
                struct.pack_into('<IIQQQQQQ', data, 64, 1, 5, 0, 0, 0, 176, 176, 4096 if fault == 'alignment' else 16384)
                struct.pack_into('<IIQQQQQQ', data, 120, 0 if fault == 'interpreter' else 3, 0, 0, 0, 0, 0, 0, 1)
                name = 'libstarintel_ecl_runner.so'
                (root / 'manifest.json').write_text(json.dumps({'abi': 'x86_64', 'eclVersion': 'synthetic',
                    'artifacts': {name: hashlib.sha256(data).hexdigest()}}))
                apk = root / 'synthetic.apk'
                with zipfile.ZipFile(apk, 'w') as out:
                    if fault != 'missing': out.writestr('lib/x86_64/' + name, data)
                    out.writestr('assets/synthetic.lisp', 'stale' if fault == 'stale' else '; synthetic fixture\n')
                if fault is None:
                    self.assertEqual(len(module.verify(apk, root)['files']), 2)
                else:
                    with self.assertRaises((AssertionError, KeyError)): module.verify(apk, root)


if __name__ == '__main__':
    unittest.main()
