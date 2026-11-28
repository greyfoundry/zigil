# Dependencies and reference data

Core typed validation, JSON decoding and schema export use Zig's standard library
only. The default build does not fetch or enable a regex engine. There is no C,
JavaScript, Python, network service or mandatory external runtime dependency.

The optional `-Dschema-regex=true` build enables the native Pike VM backend of
[ezi-gex](https://github.com/shaik-abdul-thouhid/ezi-gex), revision
`65d5477eca68905aa27ba08fba700a81f0bcab8d` (0.9.0-dev). It uses
[ezi-code](https://github.com/shaik-abdul-thouhid/ezi-code), revision
`fe7299751597c5bc167e4d9a716f1c2b1a91d70b` (0.6.0). Exact Zig content hashes are
pinned in the package manifests. Both are MIT; ezi-code also carries MIT decoder
attribution and Unicode License V3 data notices. Their package archives retain
those licence files. Binary distributors must preserve applicable dependency
notices. No upstream benchmark or security claim is adopted as Zigil evidence.

This dependency supplies Unicode properties and a native NFA; Zig's standard
library has no regex facility. Zigil selects the non-backtracking Pike VM,
constrains compilation and charges matching work before execution. Unsupported
syntax fails explicitly; there is no implicit fallback to a backtracker.

The engine was compared with quangd42/regex.zig (native, no dependencies, 0.17.1
minimum, incomplete Unicode property support) and mnemnion/mvzr (minimal Unicode).
PascalPost's older JSON Schema validator uses C++ regex and incomplete references,
so it is not a runtime dependency. Dependency additions still need human review.

Official JSON Schema validation fixtures are MIT, pinned at
`e2a68a15cd490750fd6b95e604e4054d7d978d1f`. Original bytes, licence and SHA-256
provenance live under `tests/fixtures/json-schema`; they are excluded from the
consumer package. No implementation code was copied from reference validators.

Development-only schema-export comparisons use Python `jsonschema==4.26.0`.
Mintlify `mint==4.3.96` validates documentation. Neither is needed to build or use
the native package. GitHub Actions and compiler archives are pinned in CI.
