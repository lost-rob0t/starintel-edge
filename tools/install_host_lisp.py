#!/usr/bin/env python3
"""Install the hash-pinned Sento source closure for ASDF host tests.

Requires Python 3.12+ (tarfile's data filter), not Quicklisp or a mutable dist.
The destination must not exist, so stale or locally modified sources cannot
silently affect CI. No downloaded Lisp executes during installation.
"""
import argparse
import hashlib
import io
import json
from pathlib import Path
import tarfile
import urllib.request

LOCK = Path(__file__).with_name('host-lisp-sources.json')


def install(destination, lock=LOCK):
    destination = Path(destination).resolve()
    destination.mkdir(parents=True, exist_ok=False)
    for source in json.loads(Path(lock).read_text())['sources']:
        name = source['name']
        if not name or Path(name).name != name or name in ('.', '..'):
            raise ValueError(f'Unsafe source name: {name}')
        with urllib.request.urlopen(source['url'], timeout=60) as response:
            data = response.read()
        if hashlib.sha256(data).hexdigest() != source['sha256']:
            raise ValueError(f'Archive hash mismatch: {name}')
        target = destination / name
        target.mkdir()
        with tarfile.open(fileobj=io.BytesIO(data), mode='r:gz') as archive:
            archive.extractall(target, filter='data')
        print(f'Installed verified {name}', flush=True)
    print(f'CL_SOURCE_REGISTRY={destination}//')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('destination', type=Path)
    args = parser.parse_args()
    install(args.destination)
