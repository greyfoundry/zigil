#!/usr/bin/env python3
"""Development-only independent oracle; no Python dependency in the package."""
import importlib.metadata
import json
import os
import subprocess
from pathlib import Path
from jsonschema import Draft202012Validator

assert importlib.metadata.version("jsonschema") == "4.26.0", "install jsonschema==4.26.0"
root = Path(__file__).resolve().parent.parent
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
