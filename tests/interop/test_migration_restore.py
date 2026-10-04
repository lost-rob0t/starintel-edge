#!/usr/bin/env python3
"""Restore original bytes after real SDK wire roundtrips using explicit reference.

This exercises the authority's archival restore API, not a claim that historical
reader APIs exist in each SDK. A completed, passing subprocess matrix is required.
"""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import sys
import subprocess


def require(value, message):
    if not value:
        raise RuntimeError(message)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--reference', type=Path, required=True,
                        help='Explicit StarLang compatibility directory')
    parser.add_argument('--matrix-output', type=Path, required=True)
    parser.add_argument('--historical-fixtures',type=Path,action='append',default=[])
    parser.add_argument('--canonical-fixtures',type=Path,action='append',default=[])
    args = parser.parse_args()
    root = args.reference.resolve()
    reference_commit = subprocess.check_output(['git','-C',str(root),'rev-parse','HEAD'],text=True).strip()
    require(not subprocess.check_output(['git','-C',str(root),'status','--porcelain','--untracked-files=no'],text=True), 'Reference has tracked edits; freeze before evidence capture')
    reference_files = {str(path.relative_to(root)):hashlib.sha256(path.read_bytes()).hexdigest() for path in root.glob('*.py')}
    matrix = json.loads((args.matrix_output / 'document-matrix.json').read_text())
    require(not matrix['failures'] and len(matrix['matrix']) == 25 and
            all(cell['status'] == 'passed' for cell in matrix['matrix']),
            'A complete passing five-entry-point matrix is required')
    registry = json.loads((root / 'registry.json').read_text())
    # Publication may give byte-identical local authority a different commit ID.
    # Compare executed contract bytes rather than relabeling either provenance.
    for filename in ('schema.json', 'portable-manifest.json'):
        require(registry['sha256']['../0.10.1/generated/' + filename] ==
                matrix['sdk_provenance']['python']['generated'][filename], 'Authority byte mismatch: ' + filename)
    for name, expected in registry['sha256'].items():
        require(hashlib.sha256((root / name).read_bytes()).hexdigest() == expected,
                'Migration registry hash mismatch: ' + name)
    for fixture_path in [root/'canonical-migration-fixtures.json', *args.canonical_fixtures]:
        relative=str(fixture_path.resolve().relative_to(root))
        require(matrix['fixture_sha256'].get(fixture_path.name) == registry['sha256'][relative],
                'Matrix did not execute these exact migration fixtures: '+relative)
    fixtures=[]
    for fixture_path in [root/'historical-reader-fixtures.json', *args.historical_fixtures]:
        relative=str(fixture_path.resolve().relative_to(root))
        require(hashlib.sha256(fixture_path.read_bytes()).hexdigest()==registry['sha256'][relative], 'Original fixture hash mismatch: '+relative)
        fixtures.extend(json.loads(fixture_path.read_text()))
    originals = {fixture['sourceSha256']: fixture['sourceUtf8'].encode('utf-8') for fixture in fixtures}
    require(len(originals) == len(fixtures), 'Duplicate migration originals')
    spec = importlib.util.spec_from_file_location('interop_versioned_reference', root / 'versioned_reader.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    checks = []
    for cell in matrix['matrix']:
        producer,consumer=cell['producer'],cell['consumer']
        wire = (args.matrix_output / cell['consumer_wire_file']).read_bytes()
        require(hashlib.sha256(wire).hexdigest() == cell['consumer_wire_sha256'],
                'Consumer wire evidence changed: '+producer+' -> '+consumer)
        seen = set()
        for line in wire.splitlines():
            value = module.parse(line)
            metadata = value.get('extensions', {}).get('starintelVersionedMigration')
            if metadata is None: continue
            original_hash = metadata['sourceSha256']
            require(original_hash in originals, 'Unrecognized migration source')
            require(original_hash not in seen, 'Duplicate migration source in consumer output')
            require(module.restore(line) == originals[original_hash], 'Restore changed original bytes')
            seen.add(original_hash)
        require(seen == originals.keys(), 'Consumer omitted migrated documents: '+producer+' -> '+consumer)
        checks.append({'producer':producer, 'consumer':consumer, 'restored_exact_originals':len(seen), 'status':'passed'})
    report = {'scope': 'Explicit authority archival restore after every actual producer-to-consumer SDK wire path; not SDK legacy-reader support',
              'authority_commit': matrix['authority_commit'],
              'reference_authority_commit': registry['canonicalCommit'],
              'reference_repository_commit': reference_commit,
              'reference_code_sha256': reference_files,
              'registry_sha256': hashlib.sha256((root / 'registry.json').read_bytes()).hexdigest(),
              'reference_sha256': hashlib.sha256((root / 'versioned_reader.py').read_bytes()).hexdigest(),
              'checks': checks}
    require(reference_files == {str(path.relative_to(root)):hashlib.sha256(path.read_bytes()).hexdigest() for path in root.glob('*.py')}, 'Reference code changed during restore checks')
    (args.matrix_output / 'migration-restore.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
