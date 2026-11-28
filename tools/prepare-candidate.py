#!/usr/bin/env python3
"""Prepare local review artifacts from a clean tree. Never tags or publishes."""
import datetime
import hashlib
import json
import os
import re
import shutil
import subprocess
import tarfile
import tempfile
import uuid
from pathlib import Path
root=Path(__file__).resolve().parent.parent

def git(*arguments):
    return subprocess.check_output(['git',*arguments],cwd=root,text=True).strip()

def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

if git('status','--porcelain'):
    raise SystemExit('Commit the review checkpoint first; candidate provenance requires a clean tree.')
zig=os.environ.get('ZIG','zig')
zig=str(Path(zig).resolve()) if '/' in zig else shutil.which(zig)
if not zig:raise SystemExit('Set ZIG to the verified compiler.')
compiler=subprocess.check_output([zig,'version'],text=True).strip()
if compiler!='0.17.1':raise SystemExit('Candidate baseline is Zig 0.17.1.')
version=re.search(r'\.version\s*=\s*"([^"]+)"',(root/'build.zig.zon').read_text()).group(1)
if not re.fullmatch(r'\d+\.\d+\.\d+-rc\.\d+',version):raise SystemExit('Expected an explicit unreleased release-candidate version.')
output=root/'zig-out/candidate'
output.mkdir(parents=True,exist_ok=True)
with tempfile.TemporaryDirectory(prefix='zigil-package-') as directory:
    cache=Path(directory)/'cache'
    package_hash=subprocess.check_output([zig,'fetch',str(root)],cwd=root,env=dict(os.environ,ZIG_GLOBAL_CACHE_DIR=str(cache)),text=True).strip()
    source=cache/'p'/f'{package_hash}.tar.gz'
    allowed={'build.zig','build.zig.zon','src','examples','LICENSE','NOTICE','THIRD_PARTY_NOTICES.txt','DEPENDENCIES.md','README.md','API_CONTRACT.md','COMPATIBILITY.md','CHANGELOG.md','MIGRATION.md','SECURITY.md','AI_DISCLOSURE.md','RELEASING.md','MATURITY.md'}
    required={'build.zig','build.zig.zon','src/root.zig','src/runtime.zig','src/openapi.zig','LICENSE','NOTICE','THIRD_PARTY_NOTICES.txt','API_CONTRACT.md','MIGRATION.md','SECURITY.md'}
    paths=set()
    with tarfile.open(source,'r:gz') as archive:
        for member in archive:
            parts=Path(member.name).parts
            if member.name.startswith('/') or '..' in parts or member.issym() or member.islnk():raise SystemExit(f'Unsafe archive entry: {member.name}')
            if len(parts)<=1:continue
            relative='/'.join(parts[1:])
            if parts[1] not in allowed:raise SystemExit(f'Unexpected package entry: {relative}')
            if member.isfile():paths.add(relative)
    if not required<=paths:raise SystemExit(f'Missing package source: {required-paths}')
    archive_path=output/f'zigil-{version}.tar.gz'
    shutil.copyfile(source,archive_path)

created=datetime.datetime.now(datetime.timezone.utc).isoformat(timespec='seconds').replace('+00:00','Z')
commit=git('rev-parse','HEAD')
manifest={
    'status':'unreleased review candidate; no human or security approval implied',
    'version':version,'source_commit':commit,'source_tree':git('rev-parse','HEAD^{tree}'),
    'source_url':f'https://github.com/greyfoundry/zigil/tree/{commit}',
    'created':created,'zig_package_hash':package_hash,'archive_sha256':sha(archive_path),
    'compiler':{'version':compiler,'binary_sha256':sha(Path(zig))},
    'package_files':sorted(paths),
    'approval_gates':{'human_review':'pending','independent_security_review':'pending','private_reporting_route':'unverified','release_authorization':'not granted'},
}
manifest_path=output/'provenance.json'
manifest_path.write_text(json.dumps(manifest,indent=2)+'\n')
packages=[{'SPDXID':'SPDXRef-Zigil','name':'zigil','versionInfo':version,'downloadLocation':manifest['source_url'],'filesAnalyzed':False,'licenseDeclared':'Apache-2.0','copyrightText':'Copyright 2026 Greyfoundry contributors','checksums':[{'algorithm':'SHA256','checksumValue':manifest['archive_sha256']}]}]
for identifier,name,revision,licence in [
    ('EziGex','shaik-abdul-thouhid/ezi-gex','65d5477eca68905aa27ba08fba700a81f0bcab8d','MIT'),
    ('EziCode','shaik-abdul-thouhid/ezi-code','fe7299751597c5bc167e4d9a716f1c2b1a91d70b','MIT AND Unicode-3.0'),
]:
    packages.append({'SPDXID':f'SPDXRef-{identifier}','name':name,'versionInfo':revision,'downloadLocation':f'https://github.com/{name}/tree/{revision}','filesAnalyzed':False,'licenseDeclared':licence,'copyrightText':'NOASSERTION','comment':'Optional schema-regex=true dependency; source archive carries references/notices, not this package source.'})
sbom={'spdxVersion':'SPDX-2.3','dataLicense':'CC0-1.0','SPDXID':'SPDXRef-DOCUMENT','name':f'zigil-{version}-source-inventory','documentNamespace':f'urn:uuid:{uuid.uuid4()}','creationInfo':{'creators':['Tool: Zigil prepare-candidate.py'],'created':created},'packages':packages,'relationships':[{'spdxElementId':'SPDXRef-DOCUMENT','relationshipType':'DESCRIBES','relatedSpdxElement':'SPDXRef-Zigil'},{'spdxElementId':'SPDXRef-Zigil','relationshipType':'DEPENDS_ON','relatedSpdxElement':'SPDXRef-EziGex','comment':'Optional native regex profile only.'},{'spdxElementId':'SPDXRef-EziGex','relationshipType':'DEPENDS_ON','relatedSpdxElement':'SPDXRef-EziCode'}]}
sbom_path=output/'source-inventory.spdx.json'
sbom_path.write_text(json.dumps(sbom,indent=2)+'\n')
(output/'SHA256SUMS').write_text(''.join(f'{sha(path)}  {path.name}\n' for path in (archive_path,manifest_path,sbom_path)))
print(json.dumps({'candidate':str(archive_path),'source_commit':commit,'zig_package_hash':package_hash,'sha256':manifest['archive_sha256'],'files':len(paths)}))
