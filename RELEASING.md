# Reviewing and releasing a candidate

The working branch contains an **unreleased review candidate**, not a published
1.0 release. No script merges, tags, deploys documentation or publishes packages.

1. Review the proposed API contract, migration notes, AI disclosure, known scope
   and the exact commit's required Linux/Windows/macOS, docs, conformance and
   independent consumer/oracle checks. Advisory development-compiler results are
   separate from stable support.
2. A human must review ownership, numeric fidelity, schema/ref/regex threat cases,
   budgets, dependency provenance and failure cleanup. Record reviewer identity,
   commit and findings; automated checks cannot supply this approval.
3. A Greyfoundry maintainer must verify an actual private vulnerability reporting
   route, ownership/support policy and repository protection. Do not advertise an
   unavailable route or change security settings unattended. The proposed route
   is GitHub private vulnerability reporting for this repository.
4. Review Mintlify sources and their integration into Greyfoundry's existing docs
   organization. Full validation in CI is distinct from deployment approval.
5. From a clean reviewed tree run the checks below, then
   `ZIG=/path/to/zig python3 tools/prepare-candidate.py`. It creates the allowlisted
   source archive (whose default build compiles its public examples), SHA256SUMS,
   clean commit/compiler provenance and an SPDX source
   inventory under `zig-out/candidate/`. Optional native dependencies are listed
   conditionally; their source is fetched separately by Zig. Review the actual
   inventory and notices. Generated provenance explicitly leaves human gates open.
6. Only after explicit maintainer authorization: select the final version, update
   changelog/support metadata, repeat verification, approve a tag/release and
   publish the reviewed artifacts. Deployment and release approval are separate.

```sh
zig fmt --check build.zig build.zig.zon src examples tests bench
zig build check test docs run-examples
zig build test conformance -Dschema-regex=true -Doptimize=ReleaseSafe
zig build test -Dfuzz-rounds=100 -Dschema-regex=true -Doptimize=ReleaseSafe
bash tools/check-consumer.sh -Doptimize=ReleaseSafe
bash tools/check-consumer.sh -Dschema-regex=true -Doptimize=ReleaseSafe
python3 tools/check_repository.py
python3 tools/check-conformance-source.py
python3 tools/check-schema-export.py
```

The export oracle uses `tools/oracle-requirements.txt`. Mintlify uses the pinned
CLI in CI. Local full validation currently has an OS interface-query blocker;
CI has validated the sources. Published SDK versions, compiler baselines and
supported targets must match actual evidence. No security support SLA, prior
release support window or Zig 1.0 source guarantee is asserted by this candidate.
Before 1.0, Greyfoundry must approve accountable maintenance and security support.
