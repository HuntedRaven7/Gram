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

# print("install complete") emits no trailing newline, so kernel/systemd
# output can interleave onto the same serial line. Match the marker at the
# start of a line with a non-letter boundary so a longer word cannot match.
install_marker=$'^install complete([^[:alpha:]]|$)'
deadline=$((SECONDS + install_timeout))
until grep -aqE "$install_marker" "$log1"; do
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
if ! grep -aqE "$install_marker" "$log1"; then
  echo "installer service did not succeed" >&2
  kill "$pid" 2>/dev/null || true
  exit 1
fi
echo "install completed"

shutdown_timeout="${SHUTDOWN_TIMEOUT:-90}"
if ! python3 - "$qmp" <<'PY'
import socket
import sys

sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.settimeout(10)
sock.connect(sys.argv[1])
sock.sendall(b'{"execute":"system_powerdown"}\n')
sock.close()
PY
then
  echo "QMP system_powerdown failed; guest will be terminated" >&2
fi
echo "powerdown sent; waiting up to ${shutdown_timeout}s for guest to exit"

shutdown_deadline=$((SECONDS + shutdown_timeout))
while kill -0 "$pid" 2>/dev/null; do
  if [ "$SECONDS" -ge "$shutdown_deadline" ]; then
    echo "guest ignored ACPI shutdown; terminating QEMU" >&2
    kill -TERM "$pid" 2>/dev/null || true
    term_deadline=$((SECONDS + 10))
    while kill -0 "$pid" 2>/dev/null && [ "$SECONDS" -lt "$term_deadline" ]; do
      sleep 1
    done
    if kill -0 "$pid" 2>/dev/null; then
      echo "QEMU survived SIGTERM; sending SIGKILL" >&2
      kill -KILL "$pid" 2>/dev/null || true
    fi
    break
  fi
  sleep 2
done
wait "$pid" || true
echo "install VM exited"

echo "starting second boot verification"
timeout "${boot_timeout}s" qemu-system-x86_64 "${kvm[@]}" -m 4096 -smp 2 -nographic \
  -drive "if=pflash,format=raw,readonly=on,file=$ovmf" \
  -drive "if=pflash,format=raw,file=$boot_vars" \
  -boot order=c -drive "file=$disk,if=virtio,format=qcow2" \
  -smbios 'type=11,value=io.systemd.credential:mjolnir.boot-report=1' \
  -netdev user,id=net0 -device virtio-net-pci,netdev=net0 \
  -serial mon:stdio >"$log2" 2>&1 || true
echo "second boot log captured: $log2"
echo "checking target boot signals in $log2"

image="${IMAGE:-$(
  python3 - "$root/tests/ci-install.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as config:
    print(json.load(config)["image"])
PY
)}"

status=0
pass() {
  printf 'PASS: %s\n' "$1"
}
fail() {
  printf 'FAIL: %s\n' "$1" >&2
  status=1
}

# The opt-in boot-report unit prints bootc status JSON to /dev/console when the
# SMBIOS credential above is present. A missing or wrong digest fails the run.
if bootc_status="$(
  python3 - "$log2" "$image" <<'PY'
import json
import sys

log_path, expected = sys.argv[1:]
with open(log_path, encoding="utf-8", errors="replace") as stream:
    log = stream.read()
repository, expected_digest = expected.split("@", 1)
decoder = json.JSONDecoder()
index = 0
while True:
    marker = log.find('"apiVersion"', index)
    if marker < 0:
        break
    start = log.rfind("{", 0, marker)
    if start >= 0:
        try:
            report, _ = decoder.raw_decode(log[start:])
        except ValueError:
            pass
        else:
            booted = (report.get("status") or {}).get("booted") or {}
            image_status = booted.get("image") or {}
            digest = image_status.get("imageDigest")
            reference = (image_status.get("image") or {}).get("image")
            if digest == expected_digest and isinstance(reference, str) and reference.startswith(repository):
                print(digest)
                sys.exit(0)
    index = marker + 1
print(f"no bootc status JSON for {expected} in {log_path}", file=sys.stderr)
sys.exit(1)
PY
)"; then
  pass "bootc status reports pinned image $bootc_status"
else
  fail "bootc status does not report pinned image $image"
fi

# The signed UKI cmdline carries composefs arguments; the installer ISO does
# not. Mjolnir no longer carries systemd.firstboot=no.
uki_cmdline="$(grep -a 'Command line:' "$log2" | head -n 1 || true)"
for needle in 'console=ttyS0' 'composefs.digest=' 'composefs='; do
  if printf '%s\n' "$uki_cmdline" | grep -aqF "$needle"; then
    pass "target boot: UKI cmdline has '$needle'"
  else
    fail "target boot: UKI cmdline missing '$needle'"
  fi
done

# Mjolnir has no serial getty, so no login prompt appears. Local File Systems
# shows the installed userspace started after switch-root.
if grep -aqF 'Reached target Local File Systems' "$log2"; then
  pass "target boot: reached Local File Systems"
else
  fail "target boot: did not reach Local File Systems"
fi

if installer_lines="$(grep -anF 'Gram installer' "$log2" | cut -d: -f1 | paste -sd, -)"; then
  fail "target boot: live ISO booted again (line $installer_lines)"
else
  pass "target boot: no live ISO installer"
fi

if fault_lines="$(grep -aEin 'kernel panic|call trace' "$log2")"; then
  fail "target boot: kernel panic or Call Trace detected"
  printf '%s\n' "$fault_lines" >&2
else
  pass "target boot: no kernel panic or Call Trace"
fi

if fault_lines="$(grep -aEin '\[ *FAILED *\]|Failed to start' "$log2")"; then
  fail "target boot: failed systemd units at boot"
  printf '%s\n' "$fault_lines" >&2
else
  pass "target boot: no failed systemd units"
fi

if fault_lines="$(grep -aEin 'Kernel panic|Oops|BUG:|Call Trace|DM_VERITY|I/O error' "$log2")"; then
  fail "target boot: critical kernel messages"
  printf '%s\n' "$fault_lines" >&2
else
  pass "target boot: no critical kernel messages"
fi

echo "install log: $log1"
echo "boot log: $log2"
exit "$status"
