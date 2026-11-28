# Gram

Gram is a Zig TUI installer for bootc composefs images. It installs Mjolnir and Muramasa from a registry onto a local disk from a UEFI live ISO. It also runs headless from a JSON config, which gives CI and the TUI the same command plan.

Gram follows the install path in Mjolnir's Go installer and the wizard shape in [knuckle](https://github.com/projectbluefin/knuckle). Knuckle generates Butane and never calls bootc, so Gram copies its step flow and argv runner, not its backend.

## Build and check

Zig 0.16.0 is pinned in `build.zig.zon`. Zigzag v0.1.7 is pinned by commit hash.

```sh
zig build
zig build test
./scripts/check-dry-run.sh
```

The dry-run check compares both profiles against `tests/golden/`. It never touches a disk.

## Build the ISO

The script builds a static Gram binary, exports a pinned Fedora bootc base into squashfs, adds the installer unit, generates a live initramfs with `dmsquash-live`, and writes a UEFI-only ISO with xorriso.

```sh
ZIG=/path/to/zig-0.16.0/zig ./scripts/build-iso.sh
OVMF=/path/to/OVMF_CODE.fd ./scripts/vm-test.sh
```

`vm-test.sh` boots the ISO in QEMU with OVMF and checks that `gram-installer.service` starts. Set `ISO`, `OVMF`, `DISK`, and `LOG` to override its defaults.

## Dependency updates

Renovate reads `renovate.json` through the GitHub App. It checks the Fedora bootc base digest in `scripts/build-iso.sh`, the pinned zigzag release in `build.zig.zon`, and `minimum_zig_version`. It opens PRs weekly. Nothing merges automatically.

Renovate cannot compute a Zig package hash. After a zigzag PR, run `ZIG=/path/to/zig-0.16.0/zig ./scripts/update-zigzag-hash.sh` and commit the regenerated `build.zig.zon`. The script reads the ref that Renovate wrote and reruns `zig fetch --save`.

The RPM packages installed by `dnf` during the ISO build are not tracked. They follow the Fedora base image, so updating the base digest changes them.

## CI

`ci.yml` runs on push and pull requests. It builds Gram, runs the tests, checks Zig formatting, compares the dry-run goldens, runs ShellCheck and shfmt over `scripts/*.sh`, lints workflows with zizmor, scans for secrets with gitleaks, and boots the ISO in QEMU with OVMF to confirm that `gram-installer.service` starts.

`full-install.yml` runs on push to `main`, pull requests, and manual triggers. It bakes `tests/ci-install.json` into the ISO, installs the pinned Mjolnir image onto a blank disk, reboots without the ISO, and checks the target serial login. The ISO build uses a shared composite action, and all third-party actions are pinned by commit SHA so Renovate can update them.

`secureboot.yml` runs the same install, then boots the installed disk twice under OVMF and `swtpm` to check that a signed UKI update still unlocks the state volume and that an unknown-key UKI fails to unlock with a PCR policy failure. It uploads both serial logs. The enrolled OVMF variables and both UKI fixtures are published by the Mjolnir image repo, so the job is blocked until `SECUREBOOT_FIXTURE_BASE_URL` is set. See `docs/secureboot-swtpm.md` for the contract and the image-side TODO.

`iso.yml` runs on `v*` tags and manual triggers. It uploads the ISO and `sha256sums.txt` as artifacts. On tags it publishes a GitHub release and a build provenance attestation for the ISO.

## Install profiles

A profile owns the image reference, filesystem, bootloader, minimum disk size, kernel arguments, root encryption mode, and the expected state partition label.

- `mjolnir` uses `ghcr.io/huntedraven7/mjolnir:testing`, ext4, systemd-boot, a signed UKI, and the `MjolnirState` partition. It adds the volatile-root kargs from the Mjolnir image.
- `muramasa` uses `ghcr.io/huntedraven7/muramasa:testing` and the same install mechanics. Its exact state layout is not published, so Gram accepts any partition with a label ending in `State` and warns when it finds none.

The `encrypted` config key asks for encryption, and the profile decides how. Mjolnir's install never passes `--block-setup`. Its image enrolls the encrypted state key on first boot from the signed UKI's embedded PCR signatures and public key, so a signed UKI update keeps the key usable. Gram passes no PCR key. Muramasa installs its root with `--block-setup tpm2-luks` when encryption is requested.

Both profiles call `podman run --privileged ... bootc install to-disk --composefs-backend --bootloader systemd --wipe`, with `--filesystem` taken from the profile. Mjolnir uses ext4 because its pinned image ships `mkfs.ext4` but no `mkfs.btrfs` and bootc runs mkfs inside the target image; Muramasa keeps btrfs. Gram leaves out `--run-repart`. The live ISO's systemd-repart cannot parse the target image's `Type=state` definition. The installed image creates its state partition on first boot with its own systemd-repart. Gram still verifies the ESP, the UKI, the systemd-boot loader, and the root filesystem before it reports success.

## Headless mode

```sh
./zig-out/bin/gram --dry-run --config tests/mjolnir.json --encrypt
./zig-out/bin/gram --yes --config install.json
```

`install.json` accepts the camelCase keys used by Mjolnir's installer, plus `profile`, `hostname`, `timezone`, `username`, `passwordHash`, and `sshKeys`. Set `scratchDisk` to a separate device to hold the image pull; without it, the target disk is reused and stays mounted until bootc install finishes. Secrets can come from systemd credentials under `CREDENTIALS_DIRECTORY`, `/run/credentials/gram.service/`, or `/run/credentials/@system/` instead of the JSON file.

The TUI has no direct flag for secrets. It reads the same config defaults, then asks for WiFi, registry identity, machine identity, disk, and a typed disk confirmation.

## Layout

- `src/profile.zig`: profile table.
- `src/config.zig`: config shape, JSON parsing, credential lookup, validation.
- `src/plan.zig`: pure conversion from config to an ordered action list.
- `src/runner.zig`: argv-only command runner with a dry implementation.
- `src/execute.zig`, `src/verify.zig`: system actions and post-install checks.
- `src/disk.zig`, `src/cli.zig`, `src/tui.zig`: disk parsing, headless flow, Zigzag wizard.
- `scripts/build-iso.sh`, `iso/gram-installer.service`: live ISO build and autostart.

## Decisions

Install backend. Gram starts with `to-disk` behind a profile table. Upstream calls `to-disk` mainly a demo, but Mjolnir ships it and it handles sealed UKIs and systemd-repart. `to-filesystem` stays available as a later profile for generic images.

ISO build. Gram uses its own script rather than image-builder or Mjolnir's script. The live root is a full bootc export, so the binary, NetworkManager, firmware, and pull tools share one filesystem and the initramfs stays small.

WiFi. Gram uses `nmcli` and a keyfile, as Mjolnir does. It writes the keyfile to the live root for the installer. When a state partition is already present at install time, Gram also writes the keyfile there. When no state partition is present, Gram warns and continues. WiFi and machine-ID persistence on the installed node come from first-boot provisioning in the target image. Gram fixes the machine ID with the `systemd.machine_id=` kernel argument. Neither setting depends on an install-time state-partition write.

TUI. Zigzag supplies the program, key events, and rendering. The wizard keeps one owner per field and sends the same `Plan` to the headless backend.

Mjolnir credentials. Provisioning mints a fresh join token and supplies it as a systemd credential. Gram persists the supplied values in installed state and does not call Varlink. See [docs/issue-8-credentials-design.md](docs/issue-8-credentials-design.md).

## References

The installer design came from these sources.

Installer shape and command sequence:

- [knuckle](https://github.com/projectbluefin/knuckle) supplied the step wizard and the argv runner seam. It generates Butane and does not call bootc.
- [Mjolnir's Go installer](https://github.com/HuntedRaven7/Mjolnir/tree/testing/installer) supplied the `podman run --privileged ... bootc install to-disk` command, wipe and confirmation flow, disk eligibility rules, WiFi keyfile, and post-install ESP check.
- [Mjolnir's ISO script](https://github.com/HuntedRaven7/Mjolnir/blob/testing/installer/build-iso.sh) supplied the squashfs, dracut `dmsquash-live`, systemd-boot, and xorriso layout that Gram adapts.
- [Mjolnir architecture](https://github.com/HuntedRaven7/Mjolnir/blob/testing/docs/ARCHITECTURE.md), [impermanence](https://github.com/HuntedRaven7/Mjolnir/blob/testing/docs/IMPERMANENCE.md), [security](https://github.com/HuntedRaven7/Mjolnir/blob/testing/docs/SECURITY.md), and [provisioning](https://github.com/HuntedRaven7/Mjolnir/blob/testing/docs/PROVISIONING.md) supplied the signed UKI, `MjolnirState`, volatile root, and first-boot credential assumptions.
- [Muramasa architecture](https://github.com/HuntedRaven7/Muramasa/blob/testing/docs/ARCHITECTURE.md) supplied the desktop profile assumptions.

bootc and composefs:

- [bootc installation guide](https://bootc-dev.github.io/bootc/bootc-installation.7.html) and the [to-disk](https://bootc-dev.github.io/bootc/man/bootc-install-to-disk.8.html) and [to-filesystem](https://bootc-dev.github.io/bootc/man/bootc-install-to-filesystem.8.html) man pages defined the install surface.
- [bootc composefs backend](https://bootc.dev/bootc/bootc-composefs.7.html), [sysroot layout](https://bootc-dev.github.io/bootc/bootc-sysroot.7.html), and [composefs](https://github.com/composefs/composefs) defined the digest, EROFS, verity, and state layout.
- [bootc registries and offline](https://bootc-dev.github.io/bootc/bootc-registries-and-offline.7.html) and [compatible images](https://bootc-dev.github.io/bootc/bootc-compatible-images.7.html) defined auth paths and kernel or initramfs requirements.
- [image-builder bootc ISO docs](https://osbuild.org/docs/developer-guide/projects/image-builder/advanced/bootc/isos/) informed the ISO comparison, even though Gram uses its own script.

Zig, CI, and supply chain:

- [Zig build system](https://ziglang.org/learn/build-system/) and [Zigzag](https://github.com/meszmate/zigzag) are the toolchain and TUI basis.
- [mlugg/setup-zig](https://github.com/mlugg/setup-zig) pins Zig 0.16.0 in CI.
- [Renovate regex custom managers](https://docs.renovatebot.com/modules/manager/regex/) and [GitHub Actions digest pinning](https://docs.renovatebot.com/modules/manager/github-actions/#digest-pinning-and-updating) drive dependency updates.
- [systemd-cryptenroll](https://www.freedesktop.org/software/systemd/man/latest/systemd-cryptenroll.html) and [systemd-measure](https://www.freedesktop.org/software/systemd/man/latest/systemd-measure.html) are the basis for the signed PCR design record.
- [cosign](https://github.com/sigstore/cosign) is the image signature verifier, and [artifact attestations](https://docs.github.com/en/actions/security-for-github-actions/using-artifact-attestations/using-artifact-attestations-to-establish-provenance-for-builds) are the release provenance source.
- The live root is [quay.io/fedora/fedora-bootc](https://quay.io/repository/fedora/fedora-bootc), pinned by digest in `scripts/build-iso.sh`.

## Verification status

Verified against the real artifact: unit tests pass, both dry-run goldens match, the ISO builds to `dist/gram-installer-amd64.iso`, QEMU boots it with OVMF, and `gram-installer.service` starts.

Not yet verified: a full install of a published target image, first-boot state-partition provisioning, the installed WiFi keyfile on real hardware, a real WiFi association, and interactive TUI input inside the ISO. The QEMU command in `vm-test.sh` is the base for the full install test.
