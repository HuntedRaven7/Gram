# Secure Boot unlock test

`scripts/secureboot-swtpm-test.sh` is the CI harness for issue #19. It boots the
Mjolnir disk installed by `scripts/vm-install-test.sh` twice under OVMF and
`swtpm`. Each case gets its own copy of the enrolled OVMF variable store and its
own TPM state directory, so a failed unseal in one case cannot leak into the
other. The workflow uploads both serial logs as artifacts.

## What the harness proves

| Case | UKI fixture | Required serial evidence |
| --- | --- | --- |
| signed | `uki-signed.efi` | state-volume unlock message present, TPM unseal failure absent |
| unknown | `uki-unknown.efi` | PCR policy message present, TPM unseal failure present, unlock absent |

The assertions read only the serial log. They do not inspect QEMU internals or
the host filesystem state after boot. A case fails if a required message is
missing or a forbidden message appears. The harness never downgrades a failed
assertion to a warning.

Default needles are `MjolnirState: unlocked`, `PCR policy`, and
`Failed to unseal`. Override them with `UNLOCK_NEEDLE`, `PCR_NEEDLE`, and
`UNSEAL_FAIL_NEEDLE` if the image uses different wording.

## Fixture contract

The harness reads these files from `FIXTURE_DIR`, which defaults to
`tests/fixtures/secureboot`. A missing or empty file is a blocked run. The
harness writes the blocking reason into both serial logs so the uploaded
artifacts explain the failure.

| File | Meaning |
| --- | --- |
| `OVMF_VARS.enrolled.fd` | OVMF variable store with the test Secure Boot key in PK, KEK, and db, Secure Boot enabled, copied fresh per case |
| `uki-signed.efi` | UKI signed by the enrolled test key, installed as the signed update |
| `uki-unknown.efi` | UKI signed by a different, unenrolled key |

Env overrides: `DISK`, `OVMF_CODE`, `OVMF_VARS_ENROLLED`, `UKI_SIGNED`,
`UKI_UNKNOWN`, `FIXTURE_DIR`, `ESP_DEV`, `UKI_ESP_PATH`, `WORK`, `LOG_SIGNED`,
`LOG_UNKNOWN`, `BOOT_TIMEOUT`, `SWTPM`. When `OVMF_CODE` is unset the harness
autodetects `OVMF_CODE.fd` at the usual Fedora and Debian paths. The signed and unknown UKIs are copied into
`$UKI_ESP_PATH` on `$ESP_DEV` of a throwaway copy of the installed disk with
`guestfish` before each boot.

Host tools: `qemu-system-x86_64`, `qemu-img`, `swtpm`, `guestfish`, `grep`,
`timeout`, and an OVMF firmware package. The workflow installs all of them.

## Status: blocked on the Mjolnir image repository

`SECURITY.md` states that the target image supplies the signed UKI and that key
enrollment is an operator step. Neither the enrolled variable store nor the two
UKI fixtures belong in this repository, and this checkout has no stacked fixes
from the Mjolnir image repo. `secureboot.yml` therefore provisions fixtures
only when `SECUREBOOT_FIXTURE_BASE_URL` is configured. With no source, the
harness exits nonzero and writes the TODO below into both artifacts. That is an
honest block, not a passing test.

### TODO (image side, HuntedRaven7/Mjolnir)

1. Publish `OVMF_VARS.enrolled.fd`. Generate a test PK, KEK, and db, enroll them
   in a stock OVMF variable store, enable Secure Boot in enforcing mode, and
   export the resulting `OVMF_VARS.fd` as a release asset. Keep the private key
   out of the release and track it only in the image repo's CI secrets.
2. Publish `uki-signed.efi`: a unified kernel image signed with the enrolled db
   key. This is the signed update the harness installs into the ESP.
3. Publish `uki-unknown.efi`: the same UKI signed with a separate key that is
   not in PK, KEK, or db. Keep the signed and unknown images otherwise
   identical, so the only variable is the signature.
4. Confirm the state-volume unlock path is bound to a TPM PCR policy that
   covers the booted UKI. Emit `MjolnirState: unlocked` on a successful unseal
   and both `PCR policy` and `Failed to unseal` when the policy rejects the
   unknown key. These strings are the CI assertions; if the image uses other
   wording, set the three needle env vars in `secureboot.yml` instead of
   weakening the assertions.
5. Confirm the installed layout puts the UKI at `/EFI/Linux/mjolnir.efi` on the
   first partition, or export the real values as `UKI_ESP_PATH` and `ESP_DEV`.
   The harness overwrites that exact path before boot.
6. Wire the three release assets into a URL base and set the repository
   variable `SECUREBOOT_FIXTURE_BASE_URL` in Gram. Once set, the dispatch job
   downloads them and both cases run unmodified.

Until steps 1 through 6 land, the two outcomes cannot be observed. The
acceptance criterion from issue #19 is that the signed update boots and
unlocks and the unknown-key case fails to unlock while reporting the PCR policy
failure. Both must appear in the uploaded serial logs before this scenario is
called verified.
