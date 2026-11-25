#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pin="$(grep -o 'quay.io/fedora/fedora-bootc@sha256:[a-f0-9]\{64\}' "$root/scripts/build-iso.sh" | head -n 1)"
if [ -z "$pin" ]; then
  echo "no base image pin found in scripts/build-iso.sh" >&2
  exit 1
fi
echo "checking $pin"
skopeo inspect --no-tags "docker://$pin" >/dev/null
echo "base image pin is live"
