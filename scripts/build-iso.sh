#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$ROOT/build/iso"
OUT="$ROOT/dist"
ARCH="${ARCH:-amd64}"
ZIG="${ZIG:-zig}"
BASE_IMAGE="${BASE_IMAGE:-quay.io/fedora/fedora-bootc@sha256:840da31a3e3e8055a8d1c8c0f378e66e5c7de6ebe39037bbf7e5b252f138f04d}"
BOOT_EFI="$([ "$ARCH" = arm64 ] && echo BOOTAA64.EFI || echo BOOTX64.EFI)"

for tool in "$ZIG" podman mformat mcopy mmd mksquashfs xorriso tar; do
  command -v "$tool" >/dev/null || { echo "missing tool: $tool" >&2; exit 1; }
done

rm -rf "$BUILD"
mkdir -p "$BUILD"/{esp/EFI/BOOT,esp/loader/entries,esp/LiveOS,squashfs/etc,squashfs/usr/local/bin,squashfs/usr/lib/systemd/system,squashfs/usr/lib/systemd/system/multi-user.target.wants}
mkdir -p "$OUT"

echo "==> building static installer"
"$ZIG" build --prefix "$BUILD/gram-prefix" -Doptimize=ReleaseSafe
install -m 0755 "$BUILD/gram-prefix/bin/gram" "$BUILD/squashfs/usr/local/bin/gram"

echo "==> staging live root from $BASE_IMAGE"
podman rm -f gram-iso-root >/dev/null 2>&1 || true
CID=$(podman run -d --name gram-iso-root "$BASE_IMAGE" sleep infinity)
trap 'podman rm -f "$CID" >/dev/null 2>&1 || true' EXIT
ROOTFS="$BUILD/squashfs"
podman export "$CID" | tar -x -C "$ROOTFS"
rm -rf "$ROOTFS/sysroot" \
  "$ROOTFS/usr/share/doc" "$ROOTFS/usr/share/man" "$ROOTFS/usr/share/locale" \
  "$ROOTFS/usr/share/help" "$ROOTFS/usr/share/icons" "$ROOTFS/usr/share/backgrounds" \
  "$ROOTFS/usr/share/sounds" "$ROOTFS/usr/lib/debug" "$ROOTFS/usr/src" \
  "$ROOTFS/usr/include" "$ROOTFS/var/cache" "$ROOTFS/var/lib/dnf"
find "$ROOTFS/usr/lib/systemd/system" -name 'sshd*' -delete

echo "==> installing live services"
install -Dm644 "$ROOT/iso/gram-installer.service" \
  "$ROOTFS/usr/lib/systemd/system/gram-installer.service"
ln -sf ../gram-installer.service \
  "$ROOTFS/usr/lib/systemd/system/multi-user.target.wants/gram-installer.service"

# The bootc base ships NetworkManager; install wpa_supplicant if absent. Live
# WiFi is handled by nmcli, so the daemon is required for scanning and WPA.
if ! podman exec "$CID" sh -c 'command -v wpa_supplicant' >/dev/null 2>&1; then
  echo "==> installing wpa_supplicant in live root"
  podman exec "$CID" sh -c 'dnf install -y wpa_supplicant' >/dev/null
  podman export "$CID" | tar -x -C "$ROOTFS" ./usr/sbin/wpa_supplicant ./usr/bin/wpa_supplicant 2>/dev/null || true
fi

echo "==> building live root squashfs"
mksquashfs "$ROOTFS" "$BUILD/esp/LiveOS/squashfs.img" -noappend -comp xz -no-xattrs

echo "==> building initramfs with dracut"
# dmsquash-live and img-lib are not in the default bootc image. Install the
# version-matched dracut-live package into the throwaway build container. It
# stays out of the final squashfs because only the initramfs is copied out.
podman exec "$CID" sh -c 'mkdir -p /var/roothome && dnf install -y dracut-live systemd-boot' >/dev/null
KVER=$(podman exec "$CID" sh -c 'ls /usr/lib/modules | head -n1')
[ -n "$KVER" ] || { echo "no kernel version in base image" >&2; exit 1; }
podman exec "$CID" sh -c "dracut --no-hostonly --kver '$KVER' --add 'dmsquash-live img-lib' --add-drivers isofs --force /tmp/initramfs.img"
podman cp "$CID:/tmp/initramfs.img" "$BUILD/esp/initrd.img"
podman cp "$CID:/usr/lib/modules/$KVER/vmlinuz" "$BUILD/esp/vmlinuz"

echo "==> assembling EFI system partition"
BOOT_SOURCE="${SYSTEMD_BOOT_EFI:-/usr/lib/systemd/boot/efi/systemd-boot$([ "$ARCH" = arm64 ] && echo aa64 || echo x64).efi}"
podman cp "$CID:$BOOT_SOURCE" "$BUILD/esp/EFI/BOOT/$BOOT_EFI"

cat > "$BUILD/esp/loader/loader.conf" <<'EOF'
default gram
timeout 5
editor no
EOF
# selinux=0: the squashfs-backed live root cannot carry the xattrs that the
# target image's SELinux policy expects.
cat > "$BUILD/esp/loader/entries/gram.conf" <<'EOF'
title Gram installer
linux /vmlinuz
initrd /initrd.img
options console=tty0 console=ttyS0,115200 root=live:CDLABEL=GRAM_INSTALL rd.live.dir=/LiveOS rd.live.squashimg=squashfs.img rd.live.overlay.overlayfs=1 selinux=0
EOF

EFI_IMG="$BUILD/esp/efi.img"
truncate -s 192M "$EFI_IMG"
mformat -i "$EFI_IMG" -F ::
mmd -i "$EFI_IMG" ::EFI ::EFI/BOOT ::loader ::loader/entries
mcopy -i "$EFI_IMG" "$BUILD/esp/EFI/BOOT/$BOOT_EFI" ::EFI/BOOT/$BOOT_EFI
mcopy -i "$EFI_IMG" "$BUILD/esp/loader/loader.conf" ::loader/loader.conf
mcopy -i "$EFI_IMG" "$BUILD/esp/loader/entries/gram.conf" ::loader/entries/gram.conf
mcopy -i "$EFI_IMG" "$BUILD/esp/vmlinuz" ::vmlinuz
mcopy -i "$EFI_IMG" "$BUILD/esp/initrd.img" ::initrd.img

ISO="$OUT/gram-installer-${ARCH}.iso"
xorriso -as mkisofs -o "$ISO" -R -J -joliet-long -V GRAM_INSTALL \
  -eltorito-alt-boot -e efi.img -no-emul-boot --efi-boot-part --efi-boot-image \
  "$BUILD/esp"
echo "wrote $ISO"
