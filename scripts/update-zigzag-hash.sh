#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
zig="${ZIG:-zig}"

url="$(grep -o 'git+https://github.com/meszmate/zigzag?ref=v[^"]*' "$root/build.zig.zon" | head -n 1)"
if [ -z "$url" ]; then
  echo "no pinned zigzag dependency found in build.zig.zon" >&2
  exit 1
fi

cd "$root"
"$zig" fetch --save "$url"
echo "updated zigzag hash in build.zig.zon"
