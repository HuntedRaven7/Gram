#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
iso="${ISO:-$root/dist/gram-installer-amd64.iso}"
disk="${DISK:-/tmp/gram-install-test.qcow2}"
scratch="${SCRATCH_DISK:-/tmp/gram-scratch.qcow2}"
log1="${LOG1:-/tmp/gram-install-1.log}"
log2="${LOG2:-/tmp/gram-install-2.log}"
work="${WORK:-/tmp/gram-install-work}"
ovmf="${OVMF:-}"
install_timeout="${INSTALL_TIMEOUT:-3600}"
boot_timeout="${BOOT_TIMEOUT:-600}"

if [ -z "$ovmf" ]; then
  for candidate in /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/edk2/ovmf/OVMF_CODE.fd; do
    if [ -f "$candidate" ]; then
      ovmf="$candidate"
      break
    fi
  done
fi
[ -f "$iso" ] || {
  echo "missing ISO: $iso" >&2
  exit 1
}
[ -f "$ovmf" ] || {
  echo "missing OVMF firmware" >&2
  exit 1
}

mkdir -p "$work"
qmp="$work/qmp.sock"
rm -f "$qmp"
qemu-img create -f qcow2 "$disk" 40G >/dev/null
qemu-img create -f qcow2 "$scratch" 20G >/dev/null
kvm=()
if [ -w /dev/kvm ]; then kvm=(-enable-kvm); fi

firmware=(-drive "if=pflash,format=raw,readonly=on,file=$ovmf")
vars_source="${OVMF_VARS:-}"
if [ -z "$vars_source" ]; then
  for candidate in /usr/share/OVMF/OVMF_VARS_4M.fd /usr/share/OVMF/OVMF_VARS.fd /usr/share/edk2/ovmf/OVMF_VARS.fd; do
    if [ -f "$candidate" ]; then
      vars_source="$candidate"
      break
    fi
  done
fi
install_vars="$work/install-vars.fd"
boot_vars="$work/boot-vars.fd"
if [ -n "$vars_source" ]; then
  cp "$vars_source" "$install_vars"
  cp "$vars_source" "$boot_vars"
else
  truncate -s 128K "$install_vars"
  truncate -s 128K "$boot_vars"
fi
firmware+=(-drive "if=pflash,format=raw,file=$install_vars")

qemu-system-x86_64 "${kvm[@]}" -m 4096 -smp 2 -nographic \
  "${firmware[@]}" -cdrom "$iso" -drive "file=$disk,if=virtio,format=qcow2" \
  -drive "file=$scratch,if=virtio,format=qcow2" \
  -netdev user,id=net0 -device virtio-net-pci,netdev=net0 \
  -qmp "unix:$qmp,server=on,wait=off" -serial mon:stdio >"$log1" 2>&1 &
pid=$!

deadline=$((SECONDS + install_timeout))
until grep -aq '^install complete$' "$log1"; do
  if ! kill -0 "$pid" 2>/dev/null; then break; fi
  if grep -aqE 'gram-installer\.service: (Failed with result|Main process exited, code=exited, status=[1-9])' "$log1"; then
    echo "gram-installer.service failed; log: $log1" >&2
    kill "$pid" 2>/dev/null || true
    exit 1
  fi
  if [ "$SECONDS" -ge "$deadline" ]; then
    echo "install timed out after ${install_timeout}s" >&2
    kill "$pid" 2>/dev/null || true
    exit 1
  fi
  sleep 5
done
if ! grep -aq '^install complete$' "$log1"; then
  echo "installer service did not succeed" >&2
  kill "$pid" 2>/dev/null || true
  exit 1
fi
echo "install completed"

python3 - "$qmp" <<'PY'
import socket
import sys

sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.connect(sys.argv[1])
sock.sendall(b'{"execute":"system_powerdown"}\n')
sock.close()
PY
wait "$pid" || true

timeout "${boot_timeout}s" qemu-system-x86_64 "${kvm[@]}" -m 4096 -smp 2 -nographic \
  -drive "if=pflash,format=raw,readonly=on,file=$ovmf" \
  -drive "if=pflash,format=raw,file=$boot_vars" \
  -boot order=c -drive "file=$disk,if=virtio,format=qcow2" \
  -netdev user,id=net0 -device virtio-net-pci,netdev=net0 \
  -serial mon:stdio >"$log2" 2>&1 || true

status=0
for needle in 'login:' 'systemd.firstboot=no' 'console=ttyS0'; do
  if grep -aq "$needle" "$log2"; then
    echo "target boot: found '$needle'"
  else
    echo "target boot: missing '$needle'" >&2
    status=1
  fi
done
if grep -aq 'Gram installer' "$log2"; then
  echo "target boot: live ISO booted again" >&2
  status=1
fi

# A healthy target brings up every unit and survives boot without kernel faults.
failed_units="$(grep -aE '\[FAILED\]|Failed to (start|mount)|Failed with result|Dependency failed' "$log2" || true)"
if [ -n "$failed_units" ]; then
  echo "target boot: failed systemd units detected" >&2
  printf '%s\n' "$failed_units" >&2
  status=1
else
  echo "target boot: no failed systemd units"
fi

kernel_faults="$(grep -aEi 'kernel panic|call trace' "$log2" || true)"
if [ -n "$kernel_faults" ]; then
  echo "target boot: kernel panic or Call Trace detected" >&2
  printf '%s\n' "$kernel_faults" >&2
  status=1
else
  echo "target boot: no kernel panic or Call Trace"
fi

# The signed UKI owns the command line and the kernel echoes it to the console.
uki_cmdline="$(grep -a 'Kernel command line:' "$log2" || true)"
if printf '%s\n' "$uki_cmdline" | grep -aE '(^|[[:space:]])composefs(=|\.digest=)[^[:space:]]' >/dev/null; then
  echo "target boot: UKI cmdline has composefs argument"
else
  echo "target boot: UKI cmdline missing composefs argument" >&2
  status=1
fi
# bootc status, Varlink and cosign provenance need guest execution or registry
# trust material, so they cannot be asserted from the serial log here. The
# machine id is stored in the state partition by issue 4, not in the UKI cmdline.

echo "install log: $log1"
echo "boot log: $log2"
exit "$status"
