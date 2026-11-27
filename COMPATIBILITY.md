# Compatibility

The compiler baseline is **Zig 0.17.1**, verified against the official download
index on 27 November 2026. Development snapshots are not the baseline. The Linux
archive was checked against SHA-256
`3581863e3cbcfd0fce0efc682ce7e9e93da96668a977791d356a26d2a7e9b17a`.

Zigil is version `0.0.0` and has no releases. The public API is experimental and
may change during review. Pin an exact reviewed commit when adopting it; no
backward compatibility commitment is implied by the compiler version.

Locally exercised: x86_64 Linux with Zig 0.17.1. CI is configured for native
Linux, Windows and macOS and representative cross-target compilation. Configuration
is not execution evidence; consult the exact commit's CI results. Cross-target
compilation alone does not establish runtime correctness on that platform.

Zig 1.0 readiness means keeping compiler-sensitive reflection/build code small,
using explicit ownership, retaining consumer tests and reviewing compiler changes.
It does not mean promising source compatibility with an unreleased language.
No compatibility shim, support for older compilers, or nightly support is provided.

Native values are validated without coercion. String length means bytes. Float
bounds are inclusive and finite. Enum rules reject undeclared tags of
non-exhaustive enums. `Optional` represents native `?T`, so absent versus explicit
null is not a distinction in this layer. Strict JSON decoding is implemented. Tagged-union validation, error accumulation,
JSON Schema and OpenAPI generation remain later milestones.

Before changing a public contract, update examples, regression tests, ownership
documentation and the roadmap. No performance benchmarks have been established.


The P2 foundation changes `validate` to an inferred error union of `?Issue`.
Use `try` or handle errors separately from returned invalid-data issues.
`path_capacity` is no longer an issue code; it is `error.PathCapacityExceeded`.
See CHANGELOG.md. Machine codes and ordering are documented and tested, but the
experimental pre-release API is not yet frozen for stable consumers.

A pinned 0.18 development compiler probe is advisory in CI; it does not grant
nightly support or weaken the required stable checks. Its result remains unverified
until that job executes.
