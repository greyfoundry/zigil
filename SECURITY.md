# Security

Zigil is an experimental library. No released version currently has a security
support guarantee. Fixes target the default development branch until a versioned
support policy is established.

For a suspected vulnerability, use GitHub's private vulnerability reporting when
the repository offers it. Otherwise contact a Greyfoundry maintainer through an
existing private channel and request a reporting route. Do not post exploit data,
secrets or sensitive payloads in a public issue. Private vulnerability reporting was observed disabled on 28 November 2026.
A maintainer must enable it or establish a verified private route before release;
the agent has not changed security settings. Secret scanning was also disabled.

Validate external input only after a safe decoder has produced valid native Zig
values. This API cannot make dangling pointers, fabricated slices, undefined
values or invalid enum bit patterns safe. Bound payload size before decoding and
set string/collection length limits for external data. UTF-8 validation is enabled
by default; floating-point rules reject NaN and infinity.

Built-in issues contain static messages and paths, without offending values.
Paths can contain attacker-controlled object keys; treat them as untrusted and
apply application logging/redaction policy. Runtime schema findings own their storage.
Applications own logging, redaction and custom-validator behavior. Keep the caller's
path storage alive and unchanged while reading an issue; do not share writable
path storage between concurrent calls. See `docs/errors-ownership.mdx` for the full contract.
