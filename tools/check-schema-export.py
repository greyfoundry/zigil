#!/usr/bin/env python3
"""Development-only independent oracle; no Python dependency in the package."""
import importlib.metadata
import json
import os
import subprocess
from pathlib import Path
from jsonschema import Draft202012Validator

root = Path(__file__).resolve().parent.parent
for requirement in (root/"tools/oracle-requirements.txt").read_text().splitlines():
    if not requirement or requirement.startswith("#"): continue
    name,version=requirement.split("==")
    assert importlib.metadata.version(name)==version,f"install -r tools/oracle-requirements.txt ({name})"
result = subprocess.run([os.environ.get("ZIG", "zig"), "build", "schema-oracle"], cwd=root, text=True, capture_output=True, check=True)
count = 0
for line in result.stderr.splitlines():
    if not line.startswith('{"schema":'):
        continue
    case = json.loads(line)
    Draft202012Validator.check_schema(case["schema"])
    actual = Draft202012Validator(case["schema"]).is_valid(case["data"])
    assert actual == case["valid"], case
    count += 1
assert count == 34, f"fixture count changed: {count}"
print(f"{count} exported-schema/native-decoder comparisons passed (jsonschema 4.26.0).")
