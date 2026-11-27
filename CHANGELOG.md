# Changelog

## Unreleased

- Add the experimental native validation package, compile-time schema checks,
  examples, independent package-consumer checks, CI and Mintlify sources.
- Add per-call resource limits, operational errors, fallible custom predicates
  and caller-buffer RFC 6901 JSON Pointer rendering.
- Change the foundation API from `?Issue` to an inferred error union of `?Issue`.
  Callers now use `try` or `catch`. Path exhaustion is `error.PathCapacityExceeded`,
  not an invalid-data issue code. No released version used the earlier contract.

No release or 1.0 readiness is claimed.
