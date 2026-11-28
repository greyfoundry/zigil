# Migrating foundation checkpoints to the review candidate

No public release preceded this candidate. Pin exact reviewed commits; there is
no released 0.x compatibility line to preserve.

- `validate` returns `!?Issue`. Use `try`; a caught operational failure is not a
  returned invalid-data issue. Path exhaustion is `error.PathCapacityExceeded`.
- `Code` is non-exhaustive. Include an `else` branch when switching on codes and
  use machine names rather than persisted integer ordinals.
- `decodeJson` is strict: native struct defaults and optional field omission are
  not applied implicitly. Use `Field`/`Presence` and explicit outermost `Default`
  where absence is intentional; explicit null remains separate.
- Exact float decoding rejects rounding and underflow, including subnormal and
  extended precision edge cases. Select `float_rounding = .nearest` only when the
  application deliberately permits nearest rounding.
- Keep native issue path buffers alive. Always deinit owning decoder, exported
  schema, compiled runtime schema and validation-result handles. Do not copy them.
- Export byte-length/prefix/suffix/custom/float constraints only when a future
  faithful representation is implemented; today unsupported conversion is an error.
  Use code-point lengths for JSON Schema length semantics.
- Runtime schemas use Draft 2020-12 with format annotation by default. Historical
  dialects, arbitrary metaschema evaluation and full ECMAScript regex are not
  claimed. Enable the optional native NFA explicitly via `schema-regex = true`.
- OpenAPI 3.1/3.2 fragments share the actual 3.1 base dialect URI. Discriminator
  hints do not override `oneOf` or application authorization.

See the compiled examples and independent consumer fixture for current imports.
The candidate still requires human API, security and release review.
