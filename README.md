# Zigil

Native value validation for Zig, maintained by Greyfoundry under Apache-2.0.

Zigil adds constraints to native Zig types: string length and UTF-8, numerical
bounds, booleans, enum subsets, optionals, structs, arrays, slices and custom
predicates. Rules are defined at compile time; values can be checked at runtime.
Built-ins allocate no heap memory and leave input unchanged.

**Experimental foundation, no releases.** The public API is under review. Pin a
reviewed commit before adopting it. There are no runtime dependencies or services.

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

Use **Zig 0.17.1**. From a checkout containing the foundation:

```sh
zig build check test docs run-examples
zig build test -Doptimize=ReleaseSafe
bash tools/check-consumer.sh
```

The consumer check fetches the actual source allowlist and builds/runs an
independent project outside the repository. Bash and tar are needed for that
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
- String length counts bytes; UTF-8 validation is on by default. Floats must be finite.
- `Optional` uses `?T`. Missing versus explicitly null belongs to decoding.
- Path exhaustion and resource limits return Zig errors, including for valid input.
- `Issue.jsonPointer` renders RFC 6901 paths into caller-provided byte storage.
- Custom predicates may return `bool` or an error union of `bool`; operational
  errors propagate. They own their effects and must not retain borrowed input.

Parsing/coercion, tagged-union schemas, accumulated errors, JSON Schema and OpenAPI
generation are outside this foundation. Use standard-library decoding before
validation. Zigil cannot repair invalid pointers, undefined data or unsafe casts.

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
