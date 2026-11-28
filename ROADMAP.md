# Roadmap

Each phase ends in a tested review checkpoint. Commits and pushes go to the
working review branch. Human review is required before merge; releases and docs
deployment require separate authorization. No dates or 1.0 readiness are promised.

| Phase | Target | State |
| --- | --- | --- |
| P0 | Toolchain/reference audit, compiler-tested API alternatives and decision | Three declaration probes compiled/executed; hybrid chosen, evidence in docs/design.mdx |
| P1 | Native package, independent consumer, CI, policies and Mintlify sources | Working; full local Mintlify validation has an environment blocker |
| P2 | Native constraints, bounded structured issues and explicit operational errors | Implemented with bounded traversal, operational errors and JSON Pointer rendering; review pending |
| P3 | Strict JSON decoding, presence/null, fidelity, budgets and ownership | Implemented; native tests and consumer verification |
| P4 | Composition, tagged unions, tuples/maps, refinements, defaults and transforms | Implemented; bounded recursion and local syntax formats tested |
| P5 | Deterministic Draft 2020-12 export; explicit unsupported conversion | Implemented for declared representable rules; independent comparisons pass |
| P6 | Optional external-schema evaluator, offline registries and pinned conformance | Implemented declared 2020-12 profile; 1,319 mandatory fixtures pass locally |
| P7 | OpenAPI 3.1/3.2 fragments, fuzzing, benchmarks and platform hardening | Planned |
| P8 | Stable contracts, release candidate, support policy and Zig 1.0 migration | Planned |

Alpha follows verified P0-P3; beta follows P5; release-candidate and mature gates
require the declared standards scope, resource/security evidence, supported native
CI, package verification and human review. None is a release authorization.

Strict typed decoding is distinct from JSON Schema evaluation: unknown properties,
defaults, formats, exact numbers and Unicode follow the declared layer/dialect.
Export must not silently discard native constraints or arbitrary callback behavior.
Unrepresentable conversions fail explicitly. No implicit remote reference retrieval.

Diszig, Octozig, Zocket and ForgeQueue are potential consumers, not mandatory
dependencies. Add modules and adapters only when they implement useful behavior.
