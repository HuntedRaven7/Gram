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

A profile owns the image reference, filesystem, bootloader, minimum disk size, kernel arguments, and the expected state partition label.

- `mjolnir` uses `ghcr.io/huntedraven7/mjolnir:testing`, btrfs, systemd-boot, a signed UKI, and the `MjolnirState` partition. It adds the volatile-root kargs from the Mjolnir image.
- `muramasa` uses `ghcr.io/huntedraven7/muramasa:testing` and the same install mechanics. Its exact state layout is not published, so Gram accepts any partition with a label ending in `State` and warns when it finds none.

Both profiles call `podman run --privileged ... bootc install to-disk --composefs-backend --filesystem btrfs --bootloader systemd --run-repart --wipe`. `--run-repart` creates the state partition during install so Gram can write the persistent NetworkManager keyfile before first boot. Gram verifies the ESP, the UKI, the systemd-boot loader, and the root filesystem before it reports success.

## Headless mode

```sh
./zig-out/bin/gram --dry-run --config tests/mjolnir.json --encrypt
./zig-out/bin/gram --yes --config install.json
```

`install.json` accepts the camelCase keys used by Mjolnir's installer, plus `profile`, `hostname`, `timezone`, `username`, `passwordHash`, and `sshKeys`. Secrets can come from systemd credentials under `CREDENTIALS_DIRECTORY`, `/run/credentials/gram.service/`, or `/run/credentials/@system/` instead of the JSON file.

The TUI has no direct flag for secrets. It reads the same config defaults, then asks for WiFi, registry identity, machine identity, disk, and a typed disk confirmation.

## Layout

- `src/profile.zig`: profile table.
- `src/config.zig`: config shape, JSON parsing, credential lookup, validation.
- `src/plan.zig`: pure conversion from config to an ordered action list.
- `src/runner.zig`: argv-only command runner with a dry implementation.
- `src/execute.zig`, `src/verify.zig`: system actions and post-install checks.
- `src/disk.zig`, `src/cli.zig`, `src/tui.zig`: disk parsing, headless flow, Zigzag wizard.
- `scripts/build-iso.sh`, `iso/gram-installer.service`: live ISO build and autostart.
- `.audit/`: decision trail for this run.

## Decisions

Install backend. Gram starts with `to-disk` behind a profile table. Upstream calls `to-disk` mainly a demo, but Mjolnir ships it and it handles sealed UKIs and systemd-repart. `to-filesystem` stays available as a later profile for generic images.

ISO build. Gram uses its own script rather than image-builder or Mjolnir's script. The live root is a full bootc export, so the binary, NetworkManager, firmware, and pull tools share one filesystem and the initramfs stays small.

WiFi. Gram uses `nmcli` and a keyfile, as Mjolnir does. The keyfile is written to the live root and to the persistent state partition, so the installed node joins the same network on reboot.

TUI. Zigzag supplies the program, key events, and rendering. The wizard keeps one owner per field and sends the same `Plan` to the headless backend.

## Verification status

Verified against the real artifact: unit tests pass, both dry-run goldens match, the ISO builds to `dist/gram-installer-amd64.iso`, QEMU boots it with OVMF, and `gram-installer.service` starts.

Not yet verified: a full install of a published target image, the repart state-partition keyfile path on real hardware, a real WiFi association, and interactive TUI input inside the ISO. The QEMU command in `vm-test.sh` is the base for the full install test.
