#!/usr/bin/env python3
"""Real SDK producer -> independent SDK consumer NDJSON matrix. No downloads.

Explicit SDK source paths are required; missing tools or mismatched generated
contracts are hard failures. The consumer receives producer stdout unchanged.
This is document process interoperability, not networking or actor execution.
"""
import argparse, copy, hashlib, json, os, subprocess, sys
from pathlib import Path
from decimal import Decimal
HERE = Path(__file__).resolve().parent
EDGE = HERE.parents[1]

def execute(command, data, env):
    p = subprocess.run(command, input=data, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                       env=env, timeout=180)
    if p.returncode:
        raise AssertionError(f'{command}: exit {p.returncode}\n{p.stderr.decode()[-6000:]}\n{p.stdout.decode()[-1000:]}')
    return p.stdout

def equivalent(a, b):
    if type(a) is not type(b): return False
    if isinstance(a, dict): return a.keys() == b.keys() and all(equivalent(a[k], b[k]) for k in a)
    if isinstance(a, list): return len(a) == len(b) and all(equivalent(x, y) for x, y in zip(a, b))
    return a == b

def numeric_equivalent(a, b):
    if isinstance(a, (int, Decimal)) and not isinstance(a, bool) and isinstance(b, (int, Decimal)) and not isinstance(b, bool):
        return a == b
    if type(a) is not type(b): return False
    if isinstance(a, dict): return a.keys() == b.keys() and all(numeric_equivalent(a[k], b[k]) for k in a)
    if isinstance(a, list): return len(a) == len(b) and all(numeric_equivalent(x, y) for x, y in zip(a, b))
    return a == b

class RawFixtureNumber(str):
    """An exact numeric token from trusted JSON fixture input, never a string."""

def load_fixture(text):
    def invalid(token): raise ValueError('Non-JSON numeric constant: '+token)
    return json.loads(text, parse_int=RawFixtureNumber, parse_float=RawFixtureNumber, parse_constant=invalid)

def fixture_encode(value):
    if isinstance(value, RawFixtureNumber): return str(value)
    if isinstance(value, dict):
        return '{'+','.join(json.dumps(key, ensure_ascii=False)+':'+fixture_encode(item) for key,item in value.items())+'}'
    if isinstance(value, list): return '['+','.join(fixture_encode(item) for item in value)+']'
    return json.dumps(value, ensure_ascii=False, allow_nan=False)

def exponent_integer(text):
    negative=text.startswith('-')
    digits=text.lstrip('+-')
    result=0
    for index in range(0,len(digits),500):
        chunk=digits[index:index+500]
        result=result*10**len(chunk)+int(chunk)
    return -result if negative else result

def normalized_number(token):
    # Independent symbolic oracle: compare values without Decimal's exponent
    # range or exponent-sized integer expansion. This is not an SDK validator.
    mantissa, separator, exponent = token.lower().partition('e')
    power = exponent_integer(exponent) if separator else 0
    negative = mantissa.startswith('-')
    if negative: mantissa = mantissa[1:]
    whole, dot, fraction = mantissa.partition('.')
    power -= len(fraction)
    digits = (whole + fraction).lstrip('0') or '0'
    if digits == '0': return ('number', False, '0', 0)
    significant = digits.rstrip('0')
    power += len(digits) - len(significant)
    return ('number', negative, significant, power)

def unpack_numbers(data):
    return [json.loads(line, parse_float=normalized_number, parse_int=normalized_number) for line in data.splitlines()]

def raw_numeric_corpus():
    def raw(field, value):
        return ('{"id":"fixture:numeric","dataset":"interop-synthetic","dtype":"person",'
                '"schemaVersion":"0.10.1","' + field + '":' + value + '}')
    valid = [('createdAt','9223372036854775808'), ('createdAt','1.0'), ('createdAt','1e0'),
             ('createdAt','1e400'), ('createdAt','0e-400'), ('createdAt','1e999999999999999999999'),
             ('extensions','{"fraction":0.12345678901234567890123456789}'),
             ('extensions','{"integer":9223372036854775809}'),
             ('extensions','{"large":1e400,"small":1e-400}'),
             ('extensions','{"ultraSmall":1e-999999999999999999999}')]
    invalid = [('createdAt','1.00000000000000000000000000001'), ('createdAt','1e-400'),
               ('createdAt','-1e400'), ('createdAt','"9223372036854775808"'), ('createdAt','1e-999999999999999999999')]
    encode = lambda cases: ('\n'.join(raw(*case) for case in cases)+'\n').encode()
    return valid, invalid, encode(valid), encode(invalid)

def unpack(data):
    return [json.loads(line) for line in data.splitlines()]

def pack(values):
    return ('\n'.join(fixture_encode(x) for x in values)+'\n').encode()

def main():
    if not __debug__:
        raise RuntimeError('Interop gates require Python assertions enabled; remove -O/PYTHONOPTIMIZE')
    p = argparse.ArgumentParser(description=__doc__)
    for language in ('python','cl','nim','js'): p.add_argument('--'+language+'-sdk',type=Path,required=True)
    p.add_argument('--sbcl',default='sbcl'); p.add_argument('--nim',default='nim')
    p.add_argument('--node',default='node'); p.add_argument('--python',default=sys.executable)
    p.add_argument('--output',type=Path,required=True)
    p.add_argument('--fixtures', type=Path, action='append', default=[], help='Additional explicit [{name,valid,document}] fixture files')
    a=p.parse_args(); a.output.mkdir(parents=True,exist_ok=True)
    harness_files=[*HERE.glob('document_*'), HERE/'test_documents.py', HERE/'test_harness.py']
    harness_hashes={file.name:hashlib.sha256(file.read_bytes()).hexdigest() for file in harness_files if file.is_file()}
    env=os.environ.copy()
    roots={language:getattr(a,language+'_sdk').resolve() for language in ('python','cl','nim','js')}
    for language,path in roots.items(): env['INTEROP_'+language.upper()+'_SDK']=str(path)
    release=EDGE/'schemas/starintel-0.10.1'
    schema=json.loads((release/'generated/schema.json').read_text())
    manifest=json.loads((release/'generated/portable-manifest.json').read_text())
    lock=json.loads((EDGE/'schema/starintel-schema.lock.json').read_text())
    for relative, entry in lock['vendored_files'].items():
        actual=hashlib.sha256((EDGE/relative).read_bytes()).hexdigest()
        assert actual==entry['sha256'],f'Edge authority bytes changed: {relative}'
    proofs={}
    for language,root in roots.items():
        sr=root/('starintel_canonical/_release' if language=='python' else 'schemas/starintel-0.10.1')
        if language=='nim': sr=root/'src/starintel_doc/schemas/starintel-0.10.1'
        dirty=subprocess.check_output(['git','-C',str(root),'status','--porcelain','--untracked-files=no'],text=True)
        assert not dirty,f'{language}: tracked SDK edits lack immutable provenance: {dirty}'
        hashes={}
        binding={'python':'starintel_types.py','cl':'starintel.lisp','nim':'starintel_types.nim','js':'starintel_types.ts'}[language]
        for filename in ('schema.json','portable-manifest.json',binding):
            path=sr/'generated'/filename
            digest=hashlib.sha256(path.read_bytes()).hexdigest()
            assert digest==lock['vendored_files']['schemas/starintel-0.10.1/generated/'+filename]['sha256'],f'{language}: stale {filename}'
            hashes[filename]=digest
        proofs[language]={'tracked_worktree_clean':True,'commit':subprocess.check_output(['git','-C',str(root),'rev-parse','HEAD'],text=True).strip(),'generated':hashes}
    binary=a.output.resolve()/'document_nim'
    execute([a.nim,'c','--hints:off','--warnings:off','--nimcache:'+str(a.output.resolve()/'nimcache'), '--path:'+str(roots['nim']/'src'),'-o:'+str(binary),str(HERE/'document_nim.nim')],b'',env)
    commands={'python':[a.python,str(HERE/'document_python.py')], 'js':[a.node,str(HERE/'document_js.cjs')],
              'cl':[a.sbcl,'--script',str(HERE/'document_lisp.lisp')], 'nim':[str(binary)]}
    ts_source=a.output.resolve()/'document_typescript.ts'
    ts_source.write_text((HERE/'document_typescript.ts').read_text().replace('SDK_MODULE', str(roots['js']/'src/index')))
    execute([a.node,str(roots['js']/'node_modules/typescript/bin/tsc'),'--strict','--target','es2022','--module','commonjs','--skipLibCheck',str(ts_source)],b'',env)
    commands['typescript']=[a.node,str(ts_source.with_suffix('.js'))]
    def sample(node):
        if '$ref' in node:return sample(schema['$defs'][node['$ref'].split('/')[-1]])
        if 'enum' in node:return node['enum'][0]
        if 'anyOf' in node:return sample(node['anyOf'][0])
        kind=node.get('type')
        if kind=='object':return {key:sample(node['properties'][key]) for key in node.get('required',[])}
        if kind=='array':return []
        if kind in ('integer','number'):return node.get('minimum',0)
        if kind=='boolean':return False
        if node.get('format')=='date-time':return '2026-10-03T12:00:00Z'
        if node.get('format')=='date':return '2026-10-03'
        if node.get('format')=='uri':return 'https://example.test/'
        if 'pattern' in node:
            if '@' in node['pattern']:return 'fixture@example.test'
            if '0-9().' in node['pattern']:return '+123456789'
            return '0'
        return 'fixture'
    def document(dtype):
        value=sample(schema['$defs'][''.join(x.capitalize() for x in dtype.split('-'))])
        value.update(id='fixture:'+dtype,dataset='interop-synthetic',dtype=dtype,schemaVersion='0.10.1')
        if dtype=='operation':value['phases']=[{'phaseId':'collect','objective':'Collect evidence','state':'planned'}]
        return value
    dtypes=[e['name'].split('/')[-1] for e in manifest['types'] if e['kind']=='document' and e.get('persistence','persistent')=='persistent']
    valid=[document(dtype) for dtype in dtypes]; valid_names=['dtype:'+d for d in dtypes]
    special=document('person'); special.update(fullName='café 中文 🛰️ \U0001f680\x00tail',deleted=False,
      createdAt=9007199254740993,confidence='0.1234',extensions={'interop':{'null':None,'false':False,'empty':[],
      'integer':9223372036854775807,'negative':-9007199254740993,'float':1.25,'text':'\x00🚀',
      'opaque':{'isLosslessNumber':True,'__proto__':{'polluted':True},'constructor':'ordinary data'}}})
    valid.append(special); valid_names.append('unicode-nul-absence-null-false-exact-numbers')
    invalid=[]; invalid_names=[]
    for dtype,key,value in [('wireless-network','security','wpa4'),('person','sources',[{'id':'source'}]),
       ('person','schemaVersion','0.10.2'),('person','schemaVersion','0.9.0'),('person','createdAt',-1),('person','confidence','0.12345'),
       ('person','deleted',None),('person','dtype','unknown'),('person','id','invalid space')]:
        item=document(dtype); item[key]=value; invalid.append(item); invalid_names.append(dtype+':'+key+':'+str(value))
    # Authority fixtures exercise nested optional states and operation/research semantics.
    fixture_hashes={}
    for fixture_path in [release/'research-fixtures.json',release/'supported-workflow-fixtures.json',*a.fixtures]:
        filename=fixture_path.name
        fixture_hashes[filename]=hashlib.sha256(fixture_path.read_bytes()).hexdigest()
        for fixture in load_fixture(fixture_path.read_text()):
            (valid if fixture['valid'] else invalid).append(fixture['document'])
            (valid_names if fixture['valid'] else invalid_names).append(filename+':'+fixture['name'])
    input_valid=pack(valid); input_invalid=pack(invalid)
    numeric_valid, numeric_invalid, numeric_input, numeric_bad_input = raw_numeric_corpus()
    numeric_expected = unpack_numbers(numeric_input)
    rows=[]; failures=[]
    for producer,cmd in commands.items():
        try:
            produced=execute(cmd+['roundtrip'],input_valid,env)
            assert numeric_equivalent(unpack_numbers(produced), unpack_numbers(input_valid)),f'{producer}: producer changed documents'
            numeric_produced=execute(cmd+['roundtrip'],numeric_input,env)
            assert numeric_equivalent(unpack_numbers(numeric_produced), numeric_expected),f'{producer}: lost raw numeric value'
            numeric_adversarial=execute(cmd+['emit'],numeric_bad_input,env)
            assert numeric_equivalent(unpack_numbers(numeric_adversarial), unpack_numbers(numeric_bad_input)),f'{producer}: changed invalid number'
            adversarial=execute(cmd+['emit'],input_invalid,env)
            assert numeric_equivalent(unpack_numbers(adversarial), unpack_numbers(input_invalid)),f'{producer}: invalid-wire serialization changed data'
        except Exception as exc:
            failures.append(str(exc)); rows.append({'producer':producer,'status':'failed','error':str(exc)}); continue
        (a.output/(producer+'-valid.ndjson')).write_bytes(produced)
        (a.output/(producer+'-numeric.ndjson')).write_bytes(numeric_produced)
        proofs.setdefault(producer, {})['valid_wire_sha256']=hashlib.sha256(produced).hexdigest()
        proofs[producer]['numeric_wire_sha256']=hashlib.sha256(numeric_produced).hexdigest()
        for consumer,consume in commands.items():
            row={'producer':producer,'consumer':consumer,'valid':len(valid),'invalid':len(invalid),'numeric_valid':len(numeric_valid),'numeric_invalid':len(numeric_invalid)}
            try:
                consumed=execute(consume+['roundtrip'],produced,env)
                actual=unpack_numbers(consumed)
                assert numeric_equivalent(actual, unpack_numbers(input_valid)),f'{producer}->{consumer}: changed document values/types/absence'
                wire_file=producer+'-to-'+consumer+'-valid.ndjson'
                (a.output/wire_file).write_bytes(consumed)
                row['consumer_wire_file']=wire_file
                row['consumer_wire_sha256']=hashlib.sha256(consumed).hexdigest()
                rejected=unpack(execute(consume+['reject'],adversarial,env))
                assert len(rejected)==len(invalid),'truncated rejections'
                assert all(x['accepted'] is False for x in rejected),f'accepted invalid: {[invalid_names[i] for i,x in enumerate(rejected) if x["accepted"] is not False]}'
                numeric_actual=unpack_numbers(execute(consume+['roundtrip'],numeric_produced,env))
                assert numeric_equivalent(numeric_actual, numeric_expected),f'{producer}->{consumer}: raw numeric fidelity lost'
                numeric_rejected=unpack(execute(consume+['reject'],numeric_adversarial,env))
                assert len(numeric_rejected)==len(numeric_invalid) and all(x['accepted'] is False for x in numeric_rejected),f'{producer}->{consumer}: invalid exact integer accepted'
                row['status']='passed'
            except Exception as exc: row.update(status='failed',error=str(exc)); failures.append(str(exc))
            rows.append(row); print(json.dumps(row),flush=True)
    assert harness_hashes=={file.name:hashlib.sha256(file.read_bytes()).hexdigest() for file in harness_files if file.is_file()},'harness changed during run'
    versions={name:execute(cmd,b'',env).decode().strip() for name,cmd in {
        'python':[a.python,'--version'],'node':[a.node,'--version'],
        'sbcl':[a.sbcl,'--version'],'nim':[a.nim,'--version']}.items()}
    report={'fixture_sha256':fixture_hashes,'harness_sha256':harness_hashes,'tools':versions,'authority_commit':lock['canonical_commit'],'sdk_provenance':proofs,'scope':'actual SDK subprocess NDJSON; Nim validation SDK plus native JSON codec, not full generated typed Nim codecs; TS uses JS SDK; no actor, network mesh or Android ART claim',
            'raw_numeric_valid_cases':numeric_valid,'raw_numeric_invalid_cases':numeric_invalid,'document_types':len(dtypes),'valid_cases':valid_names,'invalid_cases':invalid_names,'matrix':rows,'failures':failures,
            'not_independent_document_runtimes':{'typescript':'separate compiled TypeScript adapter; shares actual JS SDK runtime','java/kotlin/c':'Edge platform/actor boundaries only','go/rust/elisp/prolog':'no executable 0.10.1 document adapters found'}}
    (a.output/'document-matrix.json').write_text(json.dumps(report,indent=2)+'\n')
    return bool(failures)
if __name__=='__main__':sys.exit(main())
