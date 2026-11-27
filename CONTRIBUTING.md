# Contributing

Start with [AGENTS.md](AGENTS.md), [compatibility](COMPATIBILITY.md), and the
[AI policy](AI_POLICY.md). The API is experimental. A useful change includes a
concrete consumer example and tests for its failure behavior.

Install Zig 0.17.1, then run:

```sh
zig fmt --check build.zig build.zig.zon src examples tests
zig build check test docs run-examples
zig build test -Doptimize=ReleaseSafe
bash tools/check-consumer.sh
```

`zig build test` includes expected compilation failures for invalid schemas and
overflowing input literals. `zig build docs` writes Zig's native reference to
`zig-out/docs/`. The consumer check fetches the allowlisted source package and
builds a separate project in a temporary directory. It needs Bash and tar.
Set `ZIG` to a compiler path if it is not on PATH.

Keep changes focused. Describe the problem, resulting behavior, ownership and
compatibility effects, actual verification, and unresolved limitations. For a bug
fix, add a regression case exercising the public import. Prefer literal expected
paths and error codes over expectations derived from the implementation.

No runtime dependencies are currently needed. Before adding one, explain what the
standard library cannot provide and review provenance, maintenance, licences,
transitive dependencies and version pins. Do not weaken validation to make a test
pass. Store working plans, references and raw research in ignored `.private/`.

The README example comes from `examples/basic.zig`; update and compile that source
when changing the example. Mintlify sources live in `docs/`. See `docs/README.md`
for local verification and integration into the existing Greyfoundry docs site.

All contributions, including generated contributions, require human review before
merge. Report material AI assistance and what a human actually verified.
