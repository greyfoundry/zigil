#!/usr/bin/env python3
"""Check tracked private paths, basic docs navigation and skill metadata. No network."""
import json
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]


def errors():
    problems = []
    if (ROOT / '.git').exists():
        tracked = subprocess.check_output(['git', 'ls-files', '-z'], cwd=ROOT).decode('utf-8').split('\0')
        for path in filter(None, tracked):
            parts = Path(path).parts
            if any(p in {'.private', '.local', '.zig-cache', 'zig-out', 'node_modules'} for p in parts):
                problems.append(f'Forbidden tracked path: {path}')
            if (Path(path).name.startswith('.env') and Path(path).name != '.env.example') or Path(path).suffix in {'.pem', '.key'}:
                problems.append(f'Potential secret tracked: {path}')
    else:
        print('No Git metadata; tracked-path check skipped.')
    config = json.loads((ROOT / 'docs/docs.json').read_text(encoding='utf-8'))
    for group in config['navigation']['groups']:
        for page in group['pages']:
            if not isinstance(page, str) or not any((ROOT / 'docs' / (page+ext)).is_file() for ext in ('.mdx', '.md')):
                problems.append(f'Missing navigation page: {page}')
    skills = ROOT / '.agents/skills'
    for file in sorted(skills.glob('*/SKILL.md')):
        text = file.read_text(encoding='utf-8')
        front = re.match(r'^---\nname: ([a-z0-9-]+)\ndescription: (.+)\n---\n', text)
        if not front or front.group(1) != file.parent.name:
            problems.append(f'Invalid skill metadata: {file.relative_to(ROOT)}')
        mirror = ROOT / '.claude/skills' / file.parent.name / 'SKILL.md'
        if not mirror.is_file() or f'.agents/skills/{file.parent.name}/SKILL.md' not in mirror.read_text(encoding='utf-8'):
            problems.append(f'Missing Claude mirror: {file.parent.name}')
    return problems


if __name__ == '__main__':
    issues = errors()
    for issue in issues:
        print(issue, file=sys.stderr)
    if not issues:
        print('Repository metadata checks passed (not a package/secret/content audit).')
    sys.exit(bool(issues))
