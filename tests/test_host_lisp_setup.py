"""Dependency bootstrap regression tests; no network or Lisp execution."""
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import re
import tarfile
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('installer', ROOT / 'tools/install_host_lisp.py')
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)


class HostLispSetupTests(unittest.TestCase):
    def test_lock_matches_native_source_release_urls(self):
        urls = set(re.findall(r'https://beta.quicklisp.org/archive/[^"\s]+',
                              (ROOT / 'flake.nix').read_text()))
        sources = json.loads(installer.LOCK.read_text())['sources']
        self.assertEqual(urls, {source['url'] for source in sources})
        self.assertEqual(len(sources), len({source['name'] for source in sources}))
        for source in sources:
            self.assertRegex(source['sha256'], r'^[0-9a-f]{64}$')

    def install_archive(self, archive, expected, target, lock):
        lock.write_text(json.dumps({'sources': [dict(name='fixture', url='https://example.invalid/source.tgz', sha256=expected)]}))
        with patch.object(installer.urllib.request, 'urlopen', return_value=io.BytesIO(archive)):
            installer.install(target, lock)

    def archive(self, name):
        buffer = io.BytesIO()
        with tarfile.open(fileobj=buffer, mode='w:gz') as tar:
            member = tarfile.TarInfo(name)
            member.size = 4
            tar.addfile(member, io.BytesIO(b'test'))
        return buffer.getvalue()

    def test_valid_archive_and_reject_existing_destination(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); archive = self.archive('source/file.lisp')
            self.install_archive(archive, hashlib.sha256(archive).hexdigest(), root/'deps', root/'lock.json')
            self.assertEqual((root/'deps/fixture/source/file.lisp').read_bytes(), b'test')
            with self.assertRaises(FileExistsError):
                installer.install(root/'deps', root/'lock.json')

    def test_tampered_archive_never_extracts(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with self.assertRaisesRegex(ValueError, 'hash mismatch'):
                self.install_archive(self.archive('source/file.lisp'), '0'*64, root/'deps', root/'lock.json')
            self.assertEqual(list((root/'deps').iterdir()), [])

    def test_path_traversal_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); archive = self.archive('../../escape')
            with self.assertRaises(tarfile.FilterError):
                self.install_archive(archive, hashlib.sha256(archive).hexdigest(), root/'deps', root/'lock.json')
            self.assertFalse((root/'escape').exists())


if __name__ == '__main__':
    unittest.main()
