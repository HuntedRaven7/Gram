#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bin="$root/zig-out/bin/gram"
status=0

if [ ! -x "$bin" ]; then
  echo "build gram first: zig build" >&2
  exit 1
fi

check() {
  local name="$1"
  shift
  local actual
  actual="$(mktemp)"
  "$bin" --dry-run "$@" >"$actual"
  if diff -u "$root/tests/golden/$name.txt" "$actual"; then
    echo "$name dry-run: OK"
  else
    status=1
  fi
  rm -f "$actual"
}

check muramasa --profile muramasa --disk /dev/vda
check mjolnir --config tests/mjolnir.json --encrypt
exit "$status"
