"""Process boundary using the real canonical Python SDK."""
import json, os, sys
sys.path.insert(0, os.environ['INTEROP_PYTHON_SDK'])
from starintel_canonical import roundtrip_document, parse_json, stringify_json
from starintel_canonical.errors import ValidationError
for line in sys.stdin:
    value = parse_json(line)
    try:
        result = value if sys.argv[1] == 'emit' else roundtrip_document(value)
        if sys.argv[1] == 'reject': result = {'accepted': True}
    except ValidationError as exc:
        if sys.argv[1] != 'reject': raise
        result = {'accepted': False, 'error': str(exc)}
    print(stringify_json(result))
