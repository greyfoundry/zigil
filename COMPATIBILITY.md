# Compatibility

The compiler baseline is **Zig 0.17.1**, verified against the official download
index on 27 November 2026. Development snapshots are not the baseline. The Linux
archive was checked against SHA-256
`3581863e3cbcfd0fce0efc682ce7e9e93da96668a977791d356a26d2a7e9b17a`.

Zigil is version `0.0.0` and has no releases. The public API is experimental and
may change during review. Pin an exact reviewed commit when adopting it; no
backward compatibility commitment is implied by the compiler version.

Locally exercised: x86_64 Linux with Zig 0.17.1. CI is configured for native
Linux and Windows and representative cross-target compilation. Configuration
is not execution evidence; consult the exact commit's CI results. Cross-target
compilation alone does not establish runtime correctness on that platform.

Zig 1.0 readiness means keeping compiler-sensitive reflection/build code small,
using explicit ownership, retaining consumer tests and reviewing compiler changes.
It does not mean promising source compatibility with an unreleased language.
No compatibility shim, support for older compilers, or nightly support is provided.

Native values are validated without coercion. String length means bytes. Float
bounds are inclusive and finite. Enum rules reject undeclared tags of
non-exhaustive enums. `Optional` represents native `?T`, so absent versus explicit
null is not a distinction in this layer. Parsing, tagged-union validation, error
accumulation, JSON Schema and OpenAPI generation remain outside this foundation.

Before changing a public contract, update examples, regression tests, ownership
documentation and the roadmap. No performance benchmarks have been established.
