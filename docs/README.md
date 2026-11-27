# Documentation sources

`docs.json` and the navigated MDX pages form a standalone Mintlify source
root. The supplied bootstrap configuration defines the navigation and green theme. The library
does not depend on Node or Mintlify.

For local docs work, install the current `mint` CLI and run `mint validate` and
`mint broken-links` from this directory. Preview with `mint dev --no-open`.
Use CLI telemetry opt-out if appropriate to your environment.

These sources have not been connected to or published on Greyfoundry's hosted
documentation. To add them, review the existing organization's source/deployment
configuration and mount or copy these pages under its Zigil section, updating
the internal root-relative links for that section. Do not guess a live
`docs.greyfoundry.dev/zigil` route or overwrite a shared docs.json.

Native API reference is generated separately by `zig build docs` at repository
root into `zig-out/docs/`. The README's full example is compiled from
`examples/basic.zig`; the separate package build is exercised by
`tests/consumer/` through `tools/check-consumer.sh`.
