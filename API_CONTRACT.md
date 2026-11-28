# Proposed 1.0 contract

This contract accompanies the unreleased `1.0.0-rc.1` review candidate. Human
review and release authorization are pending. No stable release or independent
security approval is implied. Pin the reviewed source commit until a release.

The documented root API is the consumer contract: native rule constructors,
`validate`, `validateWithLimits`, `Issue`, `Segment`, `Code`, `Limits`, owning JSON
decoding, schema export, `runtime` compilation/evaluation and OpenAPI fragments.
`Rule.Value` is the native value type. Internal rule metadata/check functions,
allocator state fields and source module layout are implementation details.

## Validation and decoding

Native validation borrows data, never mutates it, and built-in rules allocate
nothing. It returns null on success or the first `Issue`. Zig errors mean the
operation did not complete: allocator/resource/callback failures must not be
converted to invalidity. Custom code is synchronous and trusted; budgets cannot
interrupt arbitrary callback code or repair invalid native pointers.

Strings validate UTF-8 by default; length counts bytes unless code points are
selected explicitly. Neither counts graphemes or normalizes. Numeric bounds are
inclusive; floating constraints reject non-finite values. Enum checks reject
undeclared tags. Struct rules cover every native field in declaration order.
Sequences use index order; maps use insertion order; union payload paths use
`/value` in the documented `tag`/`value` encoding.

Strict JSON rejects duplicate and unknown keys, numeric strings, overflow,
non-finite values and implicit defaults/coercions. Native optionals accept explicit
null but remain required object members. `Presence`/`Field` distinguish absent,
null and present values. Explicit `Default` substitutes only an absent field.
Explicit `Transform` validates input before invoking the callback and validates
output afterwards. Exact float decoding rejects precision loss, including
subnormal spacing; nearest rounding requires explicit opt-in.

Owning results are move-only by contract: do not copy or separately free their
children, and always deinit them. Returned storage is valid until deinit (static
fallbacks may live longer). Input may be freed immediately. Runtime findings may
outlive the compiled schema. Native issues borrow caller path storage instead.
No operation has hidden network/filesystem I/O or mandatory external services.

## Issues and budgets

Stable machine names are `too_short`, `too_long`, `invalid_utf8`, `prefix`,
`suffix`, `below_minimum`, `above_maximum`, `not_finite`, `boolean_mismatch`,
`enum_value`, `custom`, `type_mismatch`, `missing_field`, `unknown_field`,
`duplicate_field`, `invalid_number`, `null_not_allowed`,
`invalid_format`, `union_tag` and `schema_validation`. Code is non-exhaustive;
consumers must handle unknown future codes. Integer ordinals and prose wording
are not persistence/compatibility contracts.

Paths are typed field/index segments. JSON Pointer rendering follows RFC 6901;
root is empty and slash/tilde are escaped. Binary native field/key bytes that are
not valid UTF-8 return `InvalidUtf8` when rendered as Unicode JSON Pointer. Syntax errors expose byte offsets.
Duplicate-key findings currently identify the document root. Object keys in paths
are untrusted; issue messages omit offending values. Runtime findings add the
keyword and schema location. Diagnostics are fail-fast, with at most one issue.

Default resource bounds are part of the reviewed contract and are documented in
`docs/decoding.mdx` and `docs/runtime-schemas.mdx`. Valid inputs may exceed a budget
and fail operationally. Raising limits is explicit. Work counts are logical
traversal/matching charges, not exact CPU instructions or deadlines. Arena quotas
count cumulative underlying allocation requests, not only live user payload.

## Schemas and interoperability

Export is deterministic for the same rule, options and compiler. Draft 2020-12
input/output direction is explicit. Unrepresentable constraints fail with
`UnsupportedConversion`; no silent loss, invented formats or callback export.
Presence export requires a direct object field and a non-nullable, non-presence
child; unsupported nesting fails rather than broadening wire nullability.
The runtime supports the declared profile in `docs/conformance.mdx`, using explicit
offline registries, exact decimals, successful evaluated annotations and bounded
references. It never silently accepts an unknown required vocabulary. Optional
native regex uses the pinned, bounded subset; unsupported syntax is an error.
OpenAPI support covers Schema Object fragments, not whole API documents.

SDK SemVer is independent of Zig, JSON Schema and OpenAPI versions. After stable
approval, breaking documented behavior, issue names, ownership, defaults or compiler
support requires a major release or an explicitly maintained compatibility line.
Security fixes may reject previously accepted invalid inputs and must be disclosed.
No source/ABI compatibility with unreleased Zig compilers is promised.
