# Zigil

Native validation and JSON schema tools for Zig, maintained by Greyfoundry under Apache-2.0.

Zigil adds constraints to native Zig types: string length and UTF-8, numerical
bounds, booleans, enum subsets, optionals, structs, arrays, slices and custom
predicates. Rules are defined at compile time; values can be checked at runtime.
Typed validation built-ins allocate no heap memory and leave input unchanged.

**Unreleased 1.0.0-rc.1 review candidate.** Human API/security review and release
authorization remain pending. Pin a reviewed commit before adopting it. Core
builds use only the Zig standard library; the optional native regex backend is
pinned separately. No external runtime or service is required.

## Example

This is the complete compiled source in `examples/basic.zig`:

```zig
const std = @import("std");
const z = @import("zigil");

const User = struct { name: []const u8, age: u8, nickname: ?[]const u8 };
const UserRule = z.Struct(User, .{
    .name = z.String(.{ .length = .{ .min = 1, .max = 80 } }),
    .age = z.Int(u8, .{ .min = 18 }),
    .nickname = z.Optional(z.String(.{ .length = .{ .max = 40 } })),
});

pub fn main() !void {
    var path: [4]z.Segment = undefined;
    const good: User = .{ .name = "Astoris", .age = 20, .nickname = null };
    if ((try z.validate(UserRule, good, &path)) != null) return error.UnexpectedIssue;
    const bad: User = .{ .name = "", .age = 20, .nickname = null };
    const issue = (try z.validate(UserRule, bad, &path)) orelse return error.ExpectedIssue;
    // Field names and indices are separate typed segments, never an ambiguous
    // dotted string. Inspect/copy the path before reusing its backing buffer.
    if (!std.mem.eql(u8, issue.path[0].field, "name")) return error.WrongPath;
    std.debug.print("{s}: {s}\n", .{ @tagName(issue.code), issue.message });
}
```

The first call succeeds. The second returns `too_short` at the `name` field.
Paths use typed field/index segments, not ambiguous dotted strings. A returned
issue borrows the supplied path buffer; inspect or copy it before reusing it.

## Build and verify

Use **Zig 0.17.1**. From a checkout:

```sh
zig build check test docs run-examples
zig build test -Doptimize=ReleaseSafe
bash tools/check-consumer.sh
```

The consumer check fetches the actual source allowlist, compiles its distributed
examples with Zig only, and builds/runs an independent project outside the repository. Bash and tar are needed for that
check; the library and its native tests require only Zig.

For another build graph, add this checkout as a Zig package dependency named
`zigil`, then import `dependency.module("zigil")` under that name. See
[tests/consumer/build.zig](tests/consumer/build.zig) for working build wiring and
[the quickstart](docs/quickstart.mdx) for the package setup.

## Contracts and scope

- Zig owns native field types and integer widths. Zigil owns value constraints.
- Validation is fail-fast and returns `!?Issue`: null succeeds; an issue has a code,
  a path borrowing caller storage, and a static message without raw input values.
- Struct rules must cover every native field with exactly matching types.
- String length counts bytes or explicitly selected Unicode code points; UTF-8
  validation is on by default. Floats must be finite.
- `Optional` uses `?T`. Missing versus explicitly null belongs to decoding.
- Path exhaustion and resource limits return Zig errors, including for valid input.
- `Issue.jsonPointer` renders RFC 6901 paths into caller-provided byte storage.
- Custom predicates may return `bool` or an error union of `bool`; operational
  errors propagate. They own their effects and must not retain borrowed input.

Strict owning JSON decoding is available through `decodeJson`; see the
[decoding contract](docs/decoding.mdx) and compiled `examples/json.zig`.
Composition includes tagged unions, tuples/maps, refinements, explicit defaults/
transforms and bounded recursive rules. [Schema export](docs/json-schema.mdx)
emits deterministic Draft 2020-12 for representable constraints; unsupported
conversion fails explicitly. The [offline runtime evaluator](docs/runtime-schemas.mdx)
passes the declared [conformance profile](docs/conformance.mdx). [OpenAPI 3.1/3.2
fragments](docs/openapi.mdx) reuse the shared Schema Object dialect.

The native suite, failure injection, 176,800-case mutation campaign, independent
export oracle and packaged consumer provide evidence; they do not replace human
security review. See [candidate readiness](MATURITY.md), [proposed API contract](API_CONTRACT.md),
[migration notes](MIGRATION.md) and [release procedure](RELEASING.md). Diagnostics
remain fail-fast. Zigil cannot repair invalid pointers, undefined data or unsafe casts.

Read the [rule contracts](docs/validation-semantics.mdx), [ownership](docs/errors-ownership.mdx),
[design decisions](docs/design.mdx), [compatibility](COMPATIBILITY.md), and
[roadmap](ROADMAP.md). Native API reference is generated into `zig-out/docs/`.
[Mintlify sources](docs/README.md) are prepared for integration; no hosted Zigil
route or docs deployment is claimed.

Diszig, Octozig, Zocket and ForgeQueue are potential consumers, not required
integrations. No comparative performance claims have been established.

Contributions follow [CONTRIBUTING.md](CONTRIBUTING.md), [AGENTS.md](AGENTS.md),
[AI_POLICY.md](AI_POLICY.md) and [AI_DISCLOSURE.md](AI_DISCLOSURE.md). Material AI
assistance requires disclosure and human review before merge.
