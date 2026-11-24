#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
iso="${ISO:-$root/dist/gram-installer-amd64.iso}"
ovmf="${OVMF:-}"
if [ -z "$ovmf" ]; then
  for candidate in /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/edk2/ovmf/OVMF_CODE.fd; do
    if [ -f "$candidate" ]; then
      ovmf="$candidate"
      break
    fi
  done
fi
disk="${DISK:-/tmp/gram-vm-test.qcow2}"
log="${LOG:-/tmp/gram-vm-test.log}"
timeout_s="${TIMEOUT:-120}"

[ -f "$iso" ] || {
  echo "missing ISO: $iso" >&2
  exit 1
}
[ -f "$ovmf" ] || {
  echo "missing OVMF firmware: $ovmf" >&2
  exit 1
}

qemu-img create -f qcow2 "$disk" 32G >/dev/null
timeout "${timeout_s}s" qemu-system-x86_64 \
  -m 2048 -smp 2 -nographic -bios "$ovmf" \
  -cdrom "$iso" -drive "file=$disk,if=virtio,format=qcow2" \
  -netdev user,id=net0 -device virtio-net-pci,netdev=net0 \
  -serial mon:stdio >"$log" 2>&1 || true

status=0
for needle in "Gram installer" "Reached target" "gram-installer.service" "multi-user.target"; do
  if grep -aq "$needle" "$log"; then
    echo "boot check: found '$needle'"
  else
    echo "boot check: missing '$needle'" >&2
    status=1
  fi
done
if grep -aq "Started.*gram-installer.service" "$log"; then
  echo "installer service: started"
else
  echo "installer service: did not start" >&2
  status=1
fi
echo "serial log: $log"
exit "$status"
