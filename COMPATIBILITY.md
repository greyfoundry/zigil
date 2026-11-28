# Compatibility

The compiler baseline is **Zig 0.17.1**, verified against the official download
index on 28 November 2026. Development snapshots are not the baseline. The Linux
archive was checked against SHA-256
`3581863e3cbcfd0fce0efc682ce7e9e93da96668a977791d356a26d2a7e9b17a`.

Zigil is an unreleased `1.0.0-rc.1` review candidate. The proposed API contract
may change during human review. Pin an exact reviewed commit when adopting it; no
backward compatibility commitment is implied by the compiler version.

Locally exercised: x86_64 Linux with Zig 0.17.1. At checkpoint `f886f2c`,
[required CI](https://github.com/greyfoundry/zigil/actions/runs/46138787154)
passed native Linux, Windows and macOS, optional native NFA/conformance, package
consumption, independent oracle and Mintlify checks. Linux also compiled aarch64
Linux, x86_64 Windows and aarch64 macOS targets. Final candidate CI must be checked
separately. Cross compilation alone does not establish runtime correctness.

Zig 1.0 readiness means keeping compiler-sensitive reflection/build code small,
using explicit ownership, retaining consumer tests and reviewing compiler changes.
It does not mean promising source compatibility with an unreleased language.
There is no older-compiler or nightly support commitment. The observed managed/
unmanaged std.json.Array change is isolated at the schema builder boundary.

Native values are validated without coercion. String length means bytes unless code-point units are explicitly selected. Float
bounds are inclusive and finite. Enum rules reject undeclared tags of
non-exhaustive enums. `Optional` represents native `?T`, so absent versus explicit
null is not a distinction in this layer. Strict owning JSON decoding, tagged unions, composition and bounded recursive
rules are implemented. Draft 2020-12 export and an offline runtime evaluator
implement their declared profiles; see docs/json-schema.mdx and docs/runtime-schemas.mdx.
Error accumulation is not part of this fail-fast API. OpenAPI 3.1/3.2 schema
fragments use their shared base dialect; full document validation is not claimed.

Before changing a public contract, update examples, regression tests, ownership
documentation and the roadmap. A scoped direct/native benchmark and raw samples
are recorded in docs/benchmarks.json; no library-wide performance claim follows.


The P2 foundation changes `validate` to an inferred error union of `?Issue`.
Use `try` or handle errors separately from returned invalid-data issues.
`path_capacity` is no longer an issue code; it is `error.PathCapacityExceeded`.
See CHANGELOG.md. Machine codes and ordering are documented and tested, but the
experimental pre-release API is not yet frozen for stable consumers.

A pinned 0.18 development compiler probe is advisory in CI; it does not grant
nightly support or weaken the required stable checks. It exposed actual std.json.Array churn in checkpoint f886f2c; the candidate
contains a small adapter; the advisory probe passed checkpoint b423377.
This does not grant general nightly support.
