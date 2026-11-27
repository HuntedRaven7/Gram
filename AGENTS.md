# Gram — Agent Context

Audience: AI coding agents. Humans want `README.md`.

Bar: every change keeps CI green, respects the module boundaries below, and preserves the installer safety invariants. Read [`docs/SKILL.md`](docs/SKILL.md) before starting any task. It routes you to the right document for QA, CI, install changes, and design decisions.

Look up external tool docs before using them. Zig stdlib, Zigzag, bootc, skopeo, cosign, systemd-cryptenroll, and dracut all have live docs. Verify the API you plan to call. Do not guess flag names or invent library calls.

## What this repo is

A Zig 0.16 TUI installer for bootc composefs images. It runs from a UEFI live ISO, connects WiFi, pulls a signed image, installs it with `bootc install to-disk`, verifies the disk, and can boot headless from JSON for CI. It targets Mjolnir and Muramasa through a profile table.

- Module: Zig package `gram`, binary `zig-out/bin/gram`.
- License: Apache-2.0.
- Status: pre-release. No install has been proven end to end on real hardware.

## v1 supported scope

- x86_64 UEFI, unsigned ISO. The target image supplies the signed UKI.
- One target disk. No RAID, LVM, or multi-disk layouts.
- `bootc install to-disk` behind per-image profiles. `to-filesystem` is a later option.
- WiFi through NetworkManager and `nmcli`.
- Registry credentials and WiFi keys through systemd credentials, not argv.
- Headless JSON config and `--dry-run` drive the same plan as the TUI.

Anything outside this list belongs in an issue, not a PR.

## Build, test, and lint

```sh
zig build
zig build test
zig fmt --check src build.zig
./scripts/check-dry-run.sh
shellcheck scripts/*.sh
shfmt -i 2 -d scripts/*.sh
zizmor .github/workflows
gitleaks git . --config .gitleaks.toml
./scripts/check-base-pin.sh
```

`ci.yml` runs those checks on push and pull request. `scripts/build-iso.sh` builds the live ISO. `scripts/vm-test.sh` boots the ISO in QEMU with OVMF and checks that the installer service starts. `scripts/vm-install-test.sh` performs the full install and target reboot. Local Zig must be 0.16.0.

Never use `--no-verify`. A red check is not a green result.

## Safety invariants

1. Never run `bootc install`, `wipefs`, `mkswap`, `mkfs`, or mounts on the host. Disk-touching code runs in QEMU against a blank qcow2.
2. All external commands route through `src/runner.zig`. No direct process spawning elsewhere.
3. The plan is pure. It builds typed actions; `src/execute.zig` performs them.
4. Secrets come from `CREDENTIALS_DIRECTORY`, `/run/credentials/gram.service/`, or `/run/credentials/@system/`. Never put a token, WiFi key, or password hash in argv, the ISO, or the log.
5. `tests.zig` asserts that dry-run output contains no secrets. Keep that test passing.
6. Disk confirmation is typed in the TUI and required in headless mode. Do not weaken it.
7. `--dry-run` must never touch a disk or registry. Golden output protects the plan.
8. Workflow files are security-sensitive. Pin actions by commit SHA with a version comment and keep least-privilege `permissions`.

## Module boundaries

| Module | Responsibility |
| --- | --- |
| `src/profile.zig` | Image defaults, kargs, filesystem, bootloader, state label, verification expectations |
| `src/config.zig` | Config type, JSON boundary parsing, credential lookup, validation |
| `src/plan.zig` | Pure conversion from config to ordered typed actions |
| `src/runner.zig` | argv runner with real and dry implementations |
| `src/execute.zig` | Filesystem writes, state-partition persistence, command dispatch |
| `src/verify.zig` | Post-install disk, UKI, and composefs checks |
| `src/disk.zig` | `lsblk` JSON parsing and disk eligibility |
| `src/cli.zig` | Flags, headless flow, digest resolution, DNS bound, machine ID |
| `src/tui.zig` | Zigzag wizard view and key events |
| `src/tests.zig` | Cross-module behavior tests including fuzz and secret redaction |

Keep business logic out of the TUI view. Add new external commands as plan actions, not ad hoc calls in `cli.zig`.

## Architecture decisions

1. One `Plan`, two frontends. TUI and headless cannot drift because both call `cli.apply`.
2. Profiles own image-specific behavior. Do not scatter `if mjolnir` branches across modules.
3. Dry-run is a real backend. A new action must be representable and printable in dry-run.
4. Composefs backend is selected by the image. Gram does not rewrite the image's signed cmdline for Mjolnir.
5. State partition writes are idempotent and gated by the profile's state label.
6. The ISO is built from a full bootc export, so tools and firmware share one live root.
7. Renovate owns the base image digest, zigzag pin, Zig version, and action SHAs.

## Agent rules

1. Read this file, then the issue. Do not infer scope from a commit subject.
2. Declare SCOPE, GOAL, and OUT OF SCOPE before editing.
3. One PR per issue. Branch `feat/<slug>` or `fix/<slug>`. Use conventional commits.
4. Run the local checks, then push to `origin` only. Verify CI state with `gh run list --repo HuntedRaven7/Gram --limit 5` before claiming done.
5. A decision gate is not code. Record the decision in the PR body and the linked design doc.
6. Do not open a PR that claims acceptance it cannot prove. State the exact gap in the body.
7. If you discover a convention or workaround, update `AGENTS.md` or `docs/SKILL.md` in the same PR.
8. No session notes, changelog fragments from agents, or "append here" docs.

## Docs — load on demand

| Topic | Document |
| --- | --- |
| Task routing | `docs/SKILL.md` |
| Usage, profiles, decisions, verification status | `README.md` |
| Security policy and disclosure | `SECURITY.md` |
| CI and workflows | `.github/workflows/` |
