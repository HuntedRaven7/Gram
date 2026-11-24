# Gram CI and verification hardening

Goal: add CI on push and PR, ISO build and release workflow with provenance, QEMU VM test, full install test, workflow hygiene, parser fuzz test, secret-leak dry-run test, SECURITY.md, and branch protection.

- [x] Read the Principles section of poteto-mode SKILL.md
- [x] Research action SHAs and usage
- [x] Research full-install test design
- [x] Research CI hardening details
- [x] Phase A: Frame definition of done, scope, rigor
- [x] Phase B: Design workflow units and one-way doors
- [x] Unit 1: ci.yml with Zig 0.16.0, build, test, fmt check, golden check
- [x] Unit 2: shellcheck and shfmt over scripts/*.sh
- [x] Unit 3: ISO build workflow with manual and tag triggers, artifact, release, provenance
- [x] Unit 4: vm-test.sh in CI with QEMU and OVMF
- [ ] Unit 5: full install test with headless config, reboot, target check
- [x] Unit 6: workflow hygiene: least permissions, SHA pins, zizmor, gitleaks
- [x] Unit 7: fuzz JSON config parser and assert dry-run redacts secrets
- [x] Unit 8: SECURITY.md and branch protection attempt
- [x] Phase D: audit trail in .audit/gram-ci.tsv
- [ ] Phase E: verify against definition of done on real artifacts

skip: none
