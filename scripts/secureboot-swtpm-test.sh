#!/usr/bin/env bash
# Boot an installed Mjolnir disk twice under OVMF + swtpm and assert the
# signed-UKI unlock and the unknown-key PCR policy failure. The fixtures come
# from the Mjolnir image repo; see docs/secureboot-swtpm.md.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
disk="${DISK:-/tmp/gram-install-test.qcow2}"
work="${WORK:-/tmp/gram-secureboot-work}"
fixture_dir="${FIXTURE_DIR:-$root/tests/fixtures/secureboot}"
vars_enrolled="${OVMF_VARS_ENROLLED:-$fixture_dir/OVMF_VARS.enrolled.fd}"
uki_signed="${UKI_SIGNED:-$fixture_dir/uki-signed.efi}"
uki_unknown="${UKI_UNKNOWN:-$fixture_dir/uki-unknown.efi}"
esp_dev="${ESP_DEV:-/dev/sda1}"
uki_esp_path="${UKI_ESP_PATH:-/EFI/Linux/mjolnir.efi}"
log_signed="${LOG_SIGNED:-/tmp/gram-secureboot-signed.log}"
log_unknown="${LOG_UNKNOWN:-/tmp/gram-secureboot-unknown.log}"
boot_timeout="${BOOT_TIMEOUT:-600}"
swtpm_bin="${SWTPM:-swtpm}"
unlock_needle="${UNLOCK_NEEDLE:-MjolnirState: unlocked}"
pcr_needle="${PCR_NEEDLE:-PCR policy}"
unseal_fail_needle="${UNSEAL_FAIL_NEEDLE:-Failed to unseal}"

ovmf="${OVMF_CODE:-}"
if [ -z "$ovmf" ]; then
  for candidate in \
    /usr/share/OVMF/OVMF_CODE_4M.fd \
    /usr/share/OVMF/OVMF_CODE.fd \
    /usr/share/edk2/ovmf/OVMF_CODE.fd; do
    if [ -f "$candidate" ]; then
      ovmf="$candidate"
      break
    fi
  done
fi

blocked() {
  local reason="$1"
  {
    echo "BLOCKED: $reason"
    echo
    echo "This harness does not weaken or skip the unlock assertions."
    echo "The fixtures below come from the Mjolnir image repository."
    echo
    echo "TODO (image side, HuntedRaven7/Mjolnir):"
    echo "  1. Publish OVMF_VARS.enrolled.fd with PK/KEK/db holding the test key,"
    echo "     Secure Boot enabled, and a saved variable store QEMU can copy."
    echo "  2. Publish uki-signed.efi, a UKI signed by that test key."
    echo "  3. Publish uki-unknown.efi, a UKI signed by a different key."
    echo "  4. Emit '$unlock_needle' when the state volume unlocks and"
    echo "     '$pcr_needle' plus '$unseal_fail_needle' on a PCR policy miss."
    echo "  5. Keep the update at $uki_esp_path on partition $esp_dev."
    echo
    echo "Full contract: docs/secureboot-swtpm.md"
  } >&2
  {
    for log in "$log_signed" "$log_unknown"; do
      printf 'BLOCKED: %s\nSee docs/secureboot-swtpm.md for the image-side TODO.\n' "$reason" >"$log" || true
    done
  } 2>/dev/null || true
  exit 1
}

for tool in qemu-system-x86_64 qemu-img "$swtpm_bin" guestfish grep timeout; do
  command -v "$tool" >/dev/null 2>&1 || blocked "missing tool: $tool"
done

[ -n "$ovmf" ] || blocked "no OVMF_CODE firmware found on this host"
[ -s "$disk" ] || blocked "missing installed disk: $disk (run scripts/vm-install-test.sh first)"
for fixture in "$vars_enrolled" "$uki_signed" "$uki_unknown"; do
  [ -s "$fixture" ] || blocked "missing image-side fixture: $fixture"
done

mkdir -p "$work"
kvm=()
if [ -w /dev/kvm ]; then
  kvm=(-enable-kvm)
fi

# shellcheck disable=SC2329 # invoked by the EXIT trap
cleanup() {
  local pidfile
  for pidfile in "$work"/*/tpm/swtpm.pid; do
    [ -f "$pidfile" ] || continue
    kill "$(cat "$pidfile")" 2>/dev/null || true
  done
}
trap 'cleanup' EXIT

assert_present() {
  local log="$1" needle="$2" label="$3"
  if grep -aqF "$needle" "$log"; then
    echo "PASS: $label: '$needle'"
  else
    echo "FAIL: $label: missing '$needle'" >&2
    return 1
  fi
}

assert_absent() {
  local log="$1" needle="$2" label="$3"
  if grep -aqF "$needle" "$log"; then
    echo "FAIL: $label: unexpected '$needle'" >&2
    return 1
  fi
  echo "PASS: $label: absent '$needle'"
}

run_case() {
  local case="$1" uki="$2" log="$3"
  local case_work="$work/$case"
  local case_disk="$case_work/disk.qcow2"
  local case_vars="$case_work/vars.fd"
  local tpm_dir="$case_work/tpm"
  local status=0

  rm -rf "$case_work"
  mkdir -p "$tpm_dir"
  cp "$disk" "$case_disk"
  cp "$vars_enrolled" "$case_vars"

  guestfish --rw -a "$case_disk" <<EOF
run
mount $esp_dev /
upload "$uki" "$uki_esp_path"
EOF

  "$swtpm_bin" socket \
    --tpmstate "dir=$tpm_dir" \
    --ctrl "type=unixio,path=$tpm_dir/swtpm-sock" \
    --pid "file=$tpm_dir/swtpm.pid" \
    --tpm2 --daemon

  local ready=0
  for _ in $(seq 1 50); do
    if [ -S "$tpm_dir/swtpm-sock" ]; then
      ready=1
      break
    fi
    sleep 0.1
  done
  if [ "$ready" -ne 1 ]; then
    blocked "swtpm socket did not appear for $case"
  fi

  timeout "${boot_timeout}s" qemu-system-x86_64 "${kvm[@]}" \
    -m 4096 -smp 2 -nographic \
    -drive "if=pflash,format=raw,unit=0,file=$ovmf,readonly=on" \
    -drive "if=pflash,format=raw,unit=1,file=$case_vars" \
    -chardev "socket,id=chrtpm,path=$tpm_dir/swtpm-sock" \
    -tpmdev emulator,id=tpm0,chardev=chrtpm \
    -device tpm-tis,tpmdev=tpm0 \
    -drive "file=$case_disk,if=virtio,format=qcow2" \
    -netdev user,id=net0 -device virtio-net-pci,netdev=net0 \
    -serial mon:stdio >"$log" 2>&1 || true

  if [ "$case" = signed ]; then
    assert_present "$log" "$unlock_needle" "$case" || status=1
    assert_absent "$log" "$unseal_fail_needle" "$case" || status=1
  else
    assert_present "$log" "$pcr_needle" "$case" || status=1
    assert_present "$log" "$unseal_fail_needle" "$case" || status=1
    assert_absent "$log" "$unlock_needle" "$case" || status=1
  fi
  echo "serial log: $log"
  return "$status"
}

status=0
run_case signed "$uki_signed" "$log_signed" || status=1
run_case unknown "$uki_unknown" "$log_unknown" || status=1
exit "$status"
