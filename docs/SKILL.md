# Gram task routing

Read `AGENTS.md` first. This file points to the right document and check for the task in front of you. Do not load everything at once.

| Task | Load | Gate |
| --- | --- | --- |
| Change Zig code | `AGENTS.md` module boundaries | `zig build`, `zig build test`, `zig fmt --check src build.zig`, dry-run goldens |
| Add or change an install action | `src/plan.zig`, `src/execute.zig` | Dry-run golden and a behavior test in `src/tests.zig` |
| Add a profile field | `src/profile.zig`, `README.md` | Both goldens; state that image behavior is unchanged |
| Change config schema | `src/config.zig`, `tests/*.json` | Fuzz test and secret-redaction test |
| Change WiFi or persistence | `src/execute.zig` | Full-install test if state partition behavior changes |
| Change the ISO | `scripts/build-iso.sh`, `iso/gram-installer.service` | `scripts/vm-test.sh` in QEMU with OVMF |
| Run a VM test | `scripts/vm-test.sh` | Serial log contains the installer service start |
| Run a full install | `scripts/vm-install-test.sh` | Install log and target boot log both pass |
| Debug CI | `.github/workflows/ci.yml` | `zizmor .github/workflows`, then `gh run list --repo HuntedRaven7/Gram --limit 5` |
| Lint shell | `scripts/*.sh` | `shellcheck` and `shfmt -i 2 -d` |
| Review secrets handling | `SECURITY.md`, `src/tests.zig` | `gitleaks git . --config .gitleaks.toml`, secret-redaction test |
| Cut a release | `.github/workflows/iso.yml` | Tag run uploads ISO, checksums, and provenance |

## Checklist for every PR

1. State SCOPE, GOAL, and OUT OF SCOPE in the PR body.
2. Run the local checks from the task row.
3. If a check cannot run locally, say so in the PR body and name the missing artifact.
4. Never claim a full install or Secure Boot result from a stubbed harness.
5. Push to `origin`. Read back CI state before reporting done.
