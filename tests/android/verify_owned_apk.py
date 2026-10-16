#!/usr/bin/env python3
"""Verify exact packaged native/Lisp bytes before installing the disposable APK."""
import argparse
import hashlib
import json
from pathlib import Path
import struct
import zipfile


def verify(apk, bundle):
    manifest = json.loads((bundle / 'manifest.json').read_text())
    abi = manifest['abi']
    assert abi == 'x86_64', 'This acceptance harness executes x86_64 only'
    assert 'libstarintel_ecl_runner.so' in manifest['artifacts']
    proof = {'abi': abi, 'eclVersion': manifest['eclVersion'], 'files': {}}
    expected = {f'lib/{abi}/{name}': digest for name, digest in manifest['artifacts'].items()}
    for source in (bundle / 'assets').rglob('*'):
        if source.is_file():
            expected['assets/' + str(source.relative_to(bundle / 'assets'))] = hashlib.sha256(source.read_bytes()).hexdigest()
    with zipfile.ZipFile(apk) as archive:
        names = archive.namelist()
        assert len(names) == len(set(names)), 'Duplicate archive entries'
        for name, digest in expected.items():
            data = archive.read(name)
            assert hashlib.sha256(data).hexdigest() == digest, f'Stale/mismatched APK bytes: {name}'
            proof['files'][name] = digest
            if name.startswith('lib/') or (name.endswith('.fas') and data[:4] == b'\x7fELF'):
                assert data[:6] == b'\x7fELF\x02\x01', f'Expected ELF64 little endian: {name}'
                assert struct.unpack_from('<H', data, 18)[0] == 62, f'Wrong ELF machine: {name}'
                offset = struct.unpack_from('<Q', data, 32)[0]
                size, count = struct.unpack_from('<HH', data, 54)
                headers = [struct.unpack_from('<IIQQQQQQ', data, offset + i * size) for i in range(count)]
                loads = [h for h in headers if h[0] == 1]
                assert loads and all(h[7] >= 16384 for h in loads), f'ELF LOAD alignment below 16 KiB: {name}'
                if name.endswith('/libstarintel_ecl_runner.so'):
                    assert struct.unpack_from('<H', data, 16)[0] == 3, 'Runner must be PIE'
                    assert struct.unpack_from('<Q', data, 24)[0] != 0, 'Runner has no entry point'
                    assert any(h[0] == 3 for h in headers), 'Runner lacks PT_INTERP'
    return proof


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('apk', type=Path)
    parser.add_argument('bundle', type=Path)
    args = parser.parse_args()
    print(json.dumps(verify(args.apk, args.bundle), indent=2, sort_keys=True))
