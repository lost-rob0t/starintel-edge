#!/usr/bin/env python3
"""Fail-closed raw-number fidelity gate beyond the portable fixture matrix.

Uses the actual compiled adapters from a completed matrix. Deliberately preserves
input number lexemes: constructing these inputs with Python floats would erase
the very precision losses under test. Current SDK failures are NOT xfailed.
"""
import argparse
from decimal import Decimal
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
from jsonschema import Draft202012Validator

HERE = Path(__file__).resolve().parent
EDGE = HERE.parents[1]


def require(value, message):
    if not value:
        raise RuntimeError(message)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--matrix-output', type=Path, required=True)
    for name in ('python', 'cl', 'js'):
        parser.add_argument('--' + name + '-sdk', type=Path, required=True)
    parser.add_argument('--python', default=sys.executable)
    parser.add_argument('--sbcl', default='sbcl')
    parser.add_argument('--node', default='node')
    args = parser.parse_args()
    matrix = json.loads((args.matrix_output / 'document-matrix.json').read_text())
    require(not matrix['failures'] and len(matrix['matrix']) == 25, 'Completed matrix required')
    env = os.environ.copy()
    for name in ('python', 'cl', 'js'):
        root = getattr(args, name + '_sdk').resolve()
        env['INTEROP_' + name.upper() + '_SDK'] = str(root)
        head = subprocess.check_output(['git', '-C', str(root), 'rev-parse', 'HEAD'], text=True).strip()
        dirty = subprocess.check_output(['git', '-C', str(root), 'status', '--porcelain', '--untracked-files=no'], text=True)
        require(head == matrix['sdk_provenance'][name]['commit'] and not dirty, 'SDK source changed: ' + name)
    for name, digest in matrix['harness_sha256'].items():
        require(hashlib.sha256((HERE / name).read_bytes()).hexdigest() == digest, 'Adapter source changed: ' + name)
    commands = {'python': [args.python, str(HERE / 'document_python.py')],
                'js': [args.node, str(HERE / 'document_js.cjs')],
                'cl': [args.sbcl, '--script', str(HERE / 'document_lisp.lisp')],
                'nim': [str(args.matrix_output.resolve() / 'document_nim')],
                'typescript': [args.node, str(args.matrix_output.resolve() / 'document_typescript.js')]}
    schema = json.loads((EDGE / 'schemas/starintel-0.10.1/generated/schema.json').read_text())
    validator = Draft202012Validator({**schema, '$ref': '#/$defs/Person'})
    rows = []
    for field, token in [('createdAt', '9223372036854775808'),
                         ('extensions', '{"probe":{"fraction":0.12345678901234567890123456789}}'),
                         ('extensions', '{"probe":{"integer":9223372036854775809}}')]:
        raw = ('{"id":"fixture:numeric","dataset":"interop-synthetic","dtype":"person",'
               '"schemaVersion":"0.10.1","' + field + '":' + token + '}\n')
        expected = json.loads(raw, parse_float=Decimal)
        validator.validate(expected)
        for name, command in commands.items():
            process = subprocess.run(command + ['roundtrip'], input=raw, text=True, capture_output=True, env=env, timeout=60)
            exact = False
            if process.returncode == 0:
                exact = json.loads(process.stdout, parse_float=Decimal) == expected
            row = {'language': name, 'field': field, 'raw_value': token,
                   'exit_code': process.returncode, 'exact_numeric_value': exact,
                   'status': 'passed' if exact else 'failed',
                   'actual_wire': process.stdout.strip(),
                   'error': process.stderr[-2000:] if process.returncode else ''}
            rows.append(row)
            print(json.dumps(row), flush=True)
    failed = any(row['status'] != 'passed' for row in rows)
    report = {'status': 'failed' if failed else 'passed', 'authority_commit': matrix['authority_commit'],
              'scope': 'Additional schema-valid raw number boundary cases; not covered by the passing portable matrix',
              'probe_sha256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest(), 'checks': rows}
    (args.matrix_output / 'numeric-boundaries.json').write_text(json.dumps(report, indent=2) + '\n')
    return int(failed)


if __name__ == '__main__':
    sys.exit(main())
