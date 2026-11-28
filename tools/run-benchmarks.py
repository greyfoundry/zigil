#!/usr/bin/env python3
"""Cold native benchmark build and reproducible, explicitly scoped baseline."""
import json
import hashlib
import os
import platform
import statistics
import subprocess
import tempfile
import sys
import time
from pathlib import Path
root=Path(__file__).resolve().parent.parent
zig=os.environ.get('ZIG','zig')
if '/' in zig: zig=str(Path(zig).resolve())
with tempfile.TemporaryDirectory(prefix='zigil-benchmark-') as directory:
    temporary=Path(directory)
    env=dict(os.environ,ZIG_GLOBAL_CACHE_DIR=str(temporary/'global-cache'))
    started=time.perf_counter()
    build=subprocess.run([zig,'build','bench-build','-Doptimize=ReleaseSafe','--cache-dir',str(temporary/'local-cache'),'--prefix',str(temporary/'output'),'--summary','all'],cwd=root,env=env,text=True,capture_output=True)
    if build.returncode: raise RuntimeError(build.stderr)
    build_seconds=time.perf_counter()-started
    executable=temporary/'output/bin'/('zigil-bench.exe' if os.name=='nt' else 'zigil-bench')
    command=[str(executable)]
    rss_file=temporary/'rss.txt'
    if platform.system() in ('Linux','Darwin'):
        # Fresh helper avoids including the compiler's peak RSS in runtime data.
        wrapper="""import subprocess,resource,sys,pathlib
r=subprocess.run([sys.argv[1]],text=True,capture_output=True)
sys.stdout.write(r.stdout);sys.stderr.write(r.stderr)
rss=resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss
pathlib.Path(sys.argv[2]).write_text(str(rss//1024 if sys.platform=='darwin' else rss))
sys.exit(r.returncode)
"""
        command=[sys.executable,'-c',wrapper,str(executable),str(rss_file)]
    run=subprocess.run(command,cwd=root,env=env,text=True,capture_output=True,check=True)
    samples={'direct':[],'zigil':[]}
    metadata=None
    for line in run.stderr.splitlines():
        if line.startswith('SAMPLE '):
            sample=json.loads(line[7:]);samples[sample['implementation']].append(sample['ns_per_operation'])
        if line.startswith('META '):metadata=json.loads(line[5:])
    assert metadata is not None
    assert all(len(series)==21 for series in samples.values())
    cpu=platform.processor()
    if Path('/proc/cpuinfo').exists():
        cpu=next((line.split(':',1)[1].strip() for line in Path('/proc/cpuinfo').read_text().splitlines() if line.startswith('model name')),cpu)
    source_files=sorted([root/'build.zig',root/'build.zig.zon',root/'bench/main.zig',*list((root/'src').glob('*.zig'))])
    digest=hashlib.sha256()
    for source in source_files:
        digest.update(str(source.relative_to(root)).encode()+b'\0'+source.read_bytes()+b'\0')
    report={
        'source':{'git_commit':subprocess.check_output(['git','rev-parse','HEAD'],cwd=root,text=True).strip(),'worktree_dirty':bool(subprocess.check_output(['git','status','--porcelain'],cwd=root,text=True).strip()),'source_files_sha256':digest.hexdigest(),'source_files':[str(p.relative_to(root)) for p in source_files],'file_sha256':{str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest() for p in source_files},'hash_method':'sorted relative path + NUL + bytes + NUL; authoritative source snapshot when worktree is dirty'},
        'scope':'128 bounded native struct fixtures; identical first issue code/field and constraints. Fail-fast; five invalid fixture categories and one valid. Not a library-wide comparison.',
        'environment':{'os':platform.system(),'architecture':platform.machine(),'cpu':cpu,'compiler':subprocess.check_output([zig,'version'],text=True).strip(),'mode':'ReleaseSafe','shared_host':True},
        'method':{'warmup_iterations_per_implementation':5000,'sample_order':'direct then zigil, repeated; potential order bias','clock':'monotonic awake','fresh_local_and_global_build_cache':True,'build_wall_seconds':build_seconds,'binary_bytes':executable.stat().st_size,'runtime_peak_rss_kib':int(rss_file.read_text().strip()) if rss_file.exists() else None},
        'metadata':metadata,
        'batch_per_operation_nanoseconds':{name:{'median':statistics.median(series),'p95_of_21_batch_means':sorted(series)[19],'samples':series} for name,series in samples.items()},
        'limits':'Batch means are not individual-operation tail latency. Cold build time includes standard-library compilation and link work. RSS is whole-process peak, not allocation count. Fixed sample order and a shared host limit comparisons. No regression threshold or cross-language speed claim.',
    }
    destination=root/'docs/benchmarks.json'
    destination.write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps({name:{'median_ns':statistics.median(series),'p95_batch_mean_ns':sorted(series)[19]} for name,series in samples.items()}))
    print(f'Cold build {build_seconds:.2f}s; executable {executable.stat().st_size} bytes; baseline saved.')
