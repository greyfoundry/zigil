# Candidate readiness

**Status: unreleased 1.0.0-rc.1 review candidate; not yet an approved mature release.**
The requested feature phases are implemented for the declared scope. Human API/
security review, a verified private reporting route, maintenance/protection policy
and release/deployment authorization are still open. No approval is fabricated.

| Gate | Evidence/state |
| --- | --- |
| Native validation, owning decoding, composition | Implemented; public-import success, boundary, failure and lifetime tests |
| Schema export | Deterministic Draft 2020-12, explicit input/output and unsupported conversion; 34 independent comparisons |
| Runtime schemas | Declared profile passes 1,319 mandatory plus 138 optional official instances; exact exclusions in docs/conformance.mdx |
| OpenAPI | 3.1/3.2 Schema Object fragments using their actual shared dialect; no whole-document claim |
| Resource/ownership failure paths | Depth/work/size/allocation/registry/reference/NFA limits, allocation-failure injection, borrowed/owned lifetime tests |
| Adversarial campaigns | 176,800 reproducible byte/schema/decimal mutation cases passed locally; bounded coverage, not exhaustive fuzzing |
| Performance | Actual cold build and 21-sample scoped direct/native baseline in docs/benchmarks.json; no broad speed claim |
| Consumer artifacts | Fetched allowlisted source builds independently; optional NFA consumption checked in CI |
| Native platforms | Required stable Linux/Windows/macOS checks passed checkpoint f886f2c; final candidate CI must pass |
| Compiler migration | Actual std.json.Array churn isolated; advisory 0.18 probe passed checkpoint b423377 |
| Docs | Mintlify CI validation and local links pass; local full validation blocked by OS interface query; not deployed |
| Packaging | Local candidate generator audits source contents and creates checksums, compiler/commit provenance and SPDX source inventory |
| Human code/API review | Pending; this implementation is materially AI generated |
| Independent security/dependency review | Pending |
| Private reporting and secret scanning | Observed disabled on GitHub security overview, 28 November 2026; maintainer authorization needed to enable |
| Repository protection | Maintainer policy/verification pending; settings not changed unattended |
| Accountable support policy | Maintainer approval pending; no released-version SLA asserted |
| Merge, final version, release and docs deployment | Not authorized or performed |

## Scope that remains explicit

Regex is an optional bounded native subset, not every ECMAScript construct.
Format/content keywords are annotations; required format-assertion is unsupported.
Historical/cross-draft schemas, arbitrary metaschema evaluation through references,
complete annotation-output collection and legacy dependencies compatibility are not
claimed. Native callback/byte-length/binary-float constraints that cannot be
faithfully exported return UnsupportedConversion. Diagnostics remain fail-fast;
duplicate JSON object keys currently report the document root.

These are supported-profile boundaries, not placeholder implementations or silent
successes. A broader standards claim requires implementation and new evidence.
See API_CONTRACT.md, MIGRATION.md, DEPENDENCIES.md and RELEASING.md for the review
contract and exact remaining owner-controlled actions.
