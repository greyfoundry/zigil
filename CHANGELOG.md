# Changelog

## Unreleased — 1.0.0-rc.1 review candidate

- Enforced native depth budgets during conversion before field transform callbacks.

- Bounded recursive-provider re-entry independently from visible field paths in native validation and decoding.

- Corrected boolean-schema diagnostic locations to identify the actual boolean node.

- Rejected ambiguous nested/root presence export instead of broadening wire nullability.

- Prepared a proposed API/migration contract, non-exhaustive machine codes, explicit readiness gates and audited source-candidate generation with checksums, SPDX inventory and compiler/commit provenance.
- Hardened malformed URI references, charged explicit Unicode code-point scans separately, and clarified native map-key borrowing.

- Fixed strict float decoding at subnormal half-step boundaries and f80 explicit-leading-bit precision; added regression tests.

- Added OpenAPI 3.1/3.2 schema fragments, deterministic bounded mutation campaigns, longer scheduled/manual CI campaigns and a reproducible direct/native benchmark.

- Added offline bounded Draft 2020-12 evaluation, exact numeric comparisons, evaluated annotations, safe registries and an optional pinned native NFA backend. Added the pinned official conformance corpus and provenance checks.

- Added deterministic Draft 2020-12 input/output schema export, recursive definitions, explicit unsupported-conversion errors and independent oracle checks.

- Added native tuple/map/tagged-union composition, refinements, defaults, explicit decoding transforms, bounded recursive rules, code-point lengths and local syntax formats.

- Add the experimental native validation package, compile-time schema checks,
  examples, independent package-consumer checks, CI and Mintlify sources.
- Add per-call resource limits, operational errors, fallible custom predicates
  and caller-buffer RFC 6901 JSON Pointer rendering.
- Change the foundation API from `?Issue` to an inferred error union of `?Issue`.
  Callers now use `try` or `catch`. Path exhaustion is `error.PathCapacityExceeded`,
  not an invalid-data issue code. No released version used the earlier contract.

- Add strict owning JSON decoding, explicit missing/null/value presence,
  exact decimal integer conversion and opt-in float rounding.

No release or 1.0 readiness is claimed.
