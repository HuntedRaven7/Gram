#!/usr/bin/env bash
# Exercise scripts/check-boot-log.sh through its public interface with
# synthetic install and boot logs. Good logs must pass; genuine faults must fail.
set -uo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
checker="$root/scripts/check-boot-log.sh"
fixtures="$root/tests/fixtures/boot"
image='ghcr.io/huntedraven7/mjolnir@sha256:243dc4c2ae1249ff4e078e3a74b73645e2b4a2d3493730ccd0fbe853540b030b'
status=0

run_case() {
  local name="$1" want="$2" needle="$3" install="$4" boot="$5"
  local output actual
  if output="$("$checker" "$fixtures/$install" "$fixtures/$boot" "$image" 2>&1)"; then
    actual=0
  else
    actual=1
  fi
  if [ "$actual" -ne "$want" ]; then
    printf 'FAIL: %s (exit %d, want %d)\n%s\n' "$name" "$actual" "$want" "$output" >&2
    status=1
    return
  fi
  if ! printf '%s\n' "$output" | grep -qF "$needle"; then
    printf 'FAIL: %s (missing: %s)\n%s\n' "$name" "$needle" "$output" >&2
    status=1
    return
  fi
  printf 'PASS: %s\n' "$name"
}

run_case 'clean boot passes' 0 \
  'PASS: target boot: no failed systemd units' install-good.log boot-clean.log
run_case 'benign units pass with warnings' 0 \
  'WARN: skipping known-benign failed unit Wait for Network to be Online' install-good.log boot-benign-units.log
run_case 'wrong pinned digest fails' 1 \
  'FAIL: install log does not show pinned image' install-wrong-digest.log boot-benign-units.log
run_case 'unexpected failed unit fails' 1 \
  'FAIL: target boot: failed systemd units at boot' install-good.log boot-unexpected-unit.log
run_case 'lookalike unit is not allowlisted' 1 \
  'FAIL: target boot: failed systemd units at boot' install-good.log boot-lookalike-unit.log
run_case 'verity failure fails' 1 \
  'FAIL: target boot: critical kernel messages' install-good.log boot-critical.log
run_case 'kernel panic fails' 1 \
  'FAIL: target boot: kernel panic or Call Trace detected' install-good.log boot-panic.log

printf 'fixture failures: %d\n' "$status"
exit "$status"
