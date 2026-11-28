#!/usr/bin/env python3
"""Verify pinned offline conformance fixture bytes and runner inventory."""
import hashlib
import json
from pathlib import Path
root=Path(__file__).resolve().parent.parent
fixtures=root/'tests/fixtures/json-schema'
lock=json.loads((fixtures/'PROVENANCE.json').read_text())
assert lock['revision']=='e2a68a15cd490750fd6b95e604e4054d7d978d1f'
actual={str(p.relative_to(fixtures)):hashlib.sha256(p.read_bytes()).hexdigest() for p in fixtures.rglob('*') if p.is_file() and p.name!='PROVENANCE.json'}
assert actual==lock['sha256'], 'Conformance source bytes changed; review upstream and provenance.'
runner=(root/'tests/conformance_files.zig').read_text()
for name in actual:
    if name.endswith('.json'): assert f'@embedFile("fixtures/json-schema/{name}")' in runner,name
assert runner.count('@embedFile(')==sum(name.endswith('.json') for name in actual)
print(f"Pinned fixture bytes verified ({len(actual)-1} JSON files, upstream {lock['revision'][:12]}).")
