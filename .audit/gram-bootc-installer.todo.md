# Gram bootc installer, figure-it-out

Goal: design and build a Zig TUI installer for bootc composefs images, modeled on
knuckle, with WiFi, targeting Mjolnir and Muramasa, plus a reproducible ISO build.

- [x] Read the Principles section of poteto-mode SKILL.md
- [x] Phase A: Frame. Definition of done, scope, rigor level
- [x] Research: knuckle architecture and UX
- [x] Research: bootc composefs install surface and target requirements
- [x] Research: ISO build methods and recommended toolchain
- [x] Research: Zig TUI, WiFi, OCI pull, disk ops stack
- [x] Research: Mjolnir and Muramasa image specifics
- [x] Ask the user the open questions that block design
- [x] Phase B: Design the workflow, atomic units, one-way doors, fan-out plan
- [x] Unit 1: Zig 0.16 scaffold, zigzag v0.1.7 pinned, build and tests
- [x] Unit 2: profile, config, runner, disk boundary parsers
- [x] Unit 3: headless plan builder and golden dry-run for both profiles
- [x] Unit 4: system actions, WiFi persistence, post-install verification
- [x] Unit 5: Zigzag step wizard wired to the same plan
- [x] Unit 6: custom ISO script and systemd autostart unit
- [x] Unit 7: QEMU OVMF boot smoke test
- [ ] Unit 8: full target-image install and boot test
- [x] Phase D: Keep the audit trail in .audit/gram-bootc-installer.tsv
- [ ] Phase E: Verify full install against the Phase A predicate

skip: Phase B arena bakeoff. The user settled the one-way doors, so a second
prototype round would not change the design.
skip: full target-image install. The published image tags are not confirmed and
a multi-gigabyte pull exceeds this pass. The script and command line are ready.
