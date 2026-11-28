#!/usr/bin/env bash
set -euo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
zig_bin="${ZIG:-zig}"
case "$zig_bin" in
  */*) zig_bin="$(cd -- "$(dirname -- "$zig_bin")" && pwd)/$(basename -- "$zig_bin")" ;;
esac
temporary="$(mktemp -d)"
trap 'rm -rf -- "$temporary"' EXIT
mkdir -p "$temporary/consumer" "$temporary/package"
# zig fetch applies build.zig.zon's actual source allowlist. Test that artifact,
# not the repository tree, from a separate project outside this checkout.
package_hash="$(ZIG_GLOBAL_CACHE_DIR="$temporary/cache" "$zig_bin" fetch "$root")"
# Zig 0.17.1 caches fetched source packages as .tar.gz archives.
tar -xzf "$temporary/cache/p/$package_hash.tar.gz" --strip-components=1 -C "$temporary/package"
test ! -e "$temporary/package/.private"
test ! -e "$temporary/package/.git"
cp -- "$root/tests/consumer/"* "$temporary/consumer/"
cd -- "$temporary/consumer"
ZIG_GLOBAL_CACHE_DIR="$temporary/cache" "$zig_bin" build "$@"
