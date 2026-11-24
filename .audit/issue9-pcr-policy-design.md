# Issue 9 design record, signed PCR 11 state enrollment

This record resolves the enrollment questions in issue 9 for Gram and hands
back a concrete implementation plan. It is a design record. No installer code
changed, nothing was pushed, and no PR was opened.

The design is decided for Gram. Four items are blocked on the Mjolnir image
repository and are marked as such below. Gram cannot complete them alone.

## Decisions

### 1. Who signs the PCR policy

The Mjolnir release pipeline signs it. Gram never sees a private key.

The signer is the RSA key pair passed to `ukify build` as `--pcr-private-key`
and `--pcr-public-key`. `ukify` calls `systemd-measure sign` to compute the
expected PCR 11 values of each UKI and signs them. The signature lands in the
UKI `.pcrsig` section and the public half lands in `.pcrpkey`. At boot,
systemd-stub exposes those sections under `/run/systemd/`, and
systemd-cryptsetup uses them to satisfy the TPM2 `PolicyAuthorize` assertion.

Gram's job is narrower. It receives the public half as a credential and passes
it to `systemd-cryptenroll --tpm2-public-key=`. It does not generate keys, sign
policies, or embed measurements.

Add a new RSA PCR signing key to the Mjolnir release pipeline. Keep
it distinct from the DB key that `systemd-sbsign` uses for Secure Boot. The
existing `scripts/gen-dev-keys.sh` generates only X.509 Secure Boot keys, so
it does not provide this key.

### 2. How the public key reaches the installer

Use the credential path Gram already has. `Config.secret()` in `src/config.zig`
reads `$CREDENTIALS_DIRECTORY/<name>`, then `/run/credentials/gram.service/<name>`,
then `/run/credentials/@system/<name>`. `src/cli.zig` already loads
`registry-user`, `registry-token`, `wifi-ssid`, and `wifi-psk` this way.

Load a new credential named `tpm2-pcr-public-key` with that function,
write its PEM bytes to `/run/gram/tpm2-pcr-public-key.pem` with mode 0600, and
pass that path to `systemd-cryptenroll --tpm2-public-key=`. The private key
stays in the Mjolnir release pipeline.

`iso/gram-installer.service` has no `LoadCredential=` lines today. The ISO
build must supply the credential at boot, for example with
`LoadCredential=tpm2-pcr-public-key:/run/credentials/@system/tpm2-pcr-public-key`.
Mjolnir's `docs/PROVISIONING.md` already documents systemd credentials as the
delivery channel, so the public key fits the existing model.

Gram must not rely on systemd's default lookup of
`/etc/systemd/tpm2-pcr-public-key.pem`. In the live ISO a default file would be
Gram's or absent, not Mjolnir's, and silent auto-discovery would bind the slot
to the wrong key.

### 3. How PCR 7 and PCR 11 combine

One TPM2 keyslot, one AND policy.

`--tpm2-pcrs=7` adds a `PolicyPCR` assertion over the current literal PCR 7
value. PCR 7 is the Secure Boot state and the hashes of PK, KEK, db, and dbx.
`--tpm2-public-key-pcrs=11` adds a `PolicyAuthorize` assertion over PCR 11,
satisfied by any signature made with the supplied public key. systemd writes
both assertions into the same authorization policy, so the slot unlocks only
when both hold. The literal PCR 11 alternative, `--tpm2-pcrs=11`, is the thing
that breaks on every UKI update and is rejected.

The signed PCR 11 policy is what follows UKI updates. A new UKI changes PCR 11
and ships a new signature from the same key, so the slot still unlocks. A UKI
signed by an unknown key carries a different `.pcrpkey` and a signature that
the TPM cannot verify against the enrolled key, so the slot does not unlock.

Bind PCR 7 literally and PCR 11 through the signed policy. Use the default
empty policy reference for the first implementation. A signed policy with a
different reference is rejected even with the same key, so the signer and the
enrollment must agree.

The initrd-only policy is a useful hardening step. systemd-measure recommends
it for full disk encryption keys, and Mjolnir mounts state from the initrd.
It is not available on this image today. `--tpm2-public-key-policyref` and
`systemd-measure --policyref` were added in systemd 262, while Mjolnir pins
freedesktop-sdk 26.08.4, which tracks systemd 261. Defer the initrd reference
until the image moves to systemd 262 or later.

Rejected alternative: `--tpm2-public-key-pcrs=7+11`. That asks the vendor to
sign PCR 7 values, which change with firmware key updates, and gives no benefit
over the literal PCR 7 binding.

Gotcha: PCR 7 is meaningful only when Secure Boot is enabled at enrollment. If
Gram enrolls with Secure Boot off, PCR 7 is zeros and the Secure Boot half of
the policy is empty. See the test matrix for the consequence.

### 4. What happens on key rotation

A slot stores the fingerprint of the signing public key. New UKIs signed by a
new key cannot satisfy an old slot. Rotation is therefore a two-slot overlap.

Every state volume keeps a recovery key slot for the life of the
machine. Gram enrolls it before the TPM2 slot. Rotation adds a second TPM2 slot
bound to the new public key while the old slot stays. Mjolnir publishes new
signed UKIs and the new public key. Once every node boots the new UKIs, an
operator wipes the old slot by its numeric index. `--wipe-slot=tpm2` removes all
TPM2 slots, so rotation must not use it.

The recovery key matters beyond rotation. The systemd-cryptenroll manual says
key rollover requires an existing unlock mechanism, and recommends keeping one
passphrase, recovery key, FIDO2, or TPM2 credential enrolled. A recovery key is
the only option that needs no hardware and works when both TPM2 slots fail.

Gram's installer handles the first enrollment only. A rotation subcommand or a
Mjolnir first-boot unit handles later rotations. That is a follow-up task.

### 5. Block setup backend

Make the backend a profile option.

`Profile.block_setup` is `direct` for Mjolnir and `tpm2-luks` for Muramasa.
`Profile.signed_state` is `true` for Mjolnir and `false` for Muramasa. The
Mjolnir root is composefs with dm-verity and impermanent `/etc` and `/var`. All
state that must survive a reboot lives on `MjolnirState`. Removing bootc's
default TPM2 slot from that root removes the binding that a UKI update breaks.
The signed policy goes on the state volume. Muramasa keeps the current path, as
the issue's desktop note requires.

This choice assumes Mjolnir does not need LUKS on the immutable root. Confirm
that with the Mjolnir image owners before implementation. If the root must stay
encrypted, it needs its own signed-policy re-enrollment, and Gram's live ISO is
the wrong boot state in which to do it.

### 6. Enrollment timing

Gram enrolls at install time as issue 9 asks.

The alternative is a Mjolnir first-boot unit that reads the credential and
enrolls after the signed UKI is running. That is cryptographically cleaner,
because PCR 11 at that moment matches the vendor signature. It also moves code
out of Gram and contradicts the issue. Gram keeps the install-time flow and the
swtpm matrix tests the first boot of the installed system.

Two consequences are recorded here rather than hidden. First,
`--tpm2-signature` must not be used during Gram's enrollment. That option
checks the supplied signature against the current PCR state, which during
install is Gram's live ISO, not Mjolnir's signed UKI. A Mjolnir signature would
fail the check. Gram binds to the public key alone and the first boot proves
the binding. Second, the ISO must not contain a stray
`tpm2-pcr-signature.json` in `/etc/systemd`, `/run/systemd`, or
`/usr/lib/systemd`, because systemd-cryptenroll auto-discovers it and would run
the same doomed check.

### 7. Typed enrollment action

Add an `enroll_state` variant to `Action` in `src/plan.zig` instead
of appending a raw command with a guessed device name.

`plan.zig` is a pure config to actions function. It cannot know which device
the state partition occupies. `execute.zig` already resolves that at runtime
with `findState()`, which `persistWifi()` uses. The new action carries the
paths, PCR selections, and state label. `execute.zig` resolves the device and
runs the commands. This keeps the plan pure and keeps one owner for state
partition lookup.

## Evidence

| Claim | Source |
| --- | --- |
| `--tpm2-public-key` binds to the public half of the signing key, default path is `tpm2-pcr-public-key.pem` | https://www.freedesktop.org/software/systemd/man/latest/systemd-cryptenroll.html |
| `--tpm2-public-key-pcrs` defaults to 11 and follows any signature from that key, unlike literal `--tpm2-pcrs` | https://www.freedesktop.org/software/systemd/man/latest/systemd-cryptenroll.html |
| `--tpm2-signature` is checked against the current PCR state before writing a slot | https://www.freedesktop.org/software/systemd/man/latest/systemd-cryptenroll.html |
| `--tpm2-public-key-policyref` must match the signer's policy reference | https://www.freedesktop.org/software/systemd/man/latest/systemd-cryptenroll.html |
| key rollover needs an existing unlock mechanism | https://www.freedesktop.org/software/systemd/man/latest/systemd-cryptenroll.html |
| PCR 7 is Secure Boot state, PCR 11 is systemd-stub UKI measurement | https://www.freedesktop.org/software/systemd/man/latest/systemd-cryptenroll.html |
| `systemd-measure sign` signs PCR 11, `ukify` embeds `.pcrsig` and `.pcrpkey`, initrd policy reference is recommended for FDE | https://www.freedesktop.org/software/systemd/man/latest/systemd-measure.html |
| `bootc install to-disk --block-setup` accepts only `direct` and `tpm2-luks`; encryption is owned by the installer, not bootc | https://bootc.dev/bootc/bootc-filesystem-encryption.7.html |
| Gram credential paths and plan action shape | `src/config.zig`, `src/cli.zig`, `src/plan.zig`, `src/execute.zig` |
| Mjolnir UKI uses Secure Boot keys only, no PCR signing flags | `elements/uki/mjolnir-uki.bst`, `elements/uki/boot-keys.bst` on `testing` |
| Mjolnir state partition is btrfs with no `Encrypt=` | `files/config/repart.d/20-mjolnir-state.conf` on `testing` |
| Mjolnir delivers node configuration as systemd credentials | `docs/PROVISIONING.md` on `testing` |
| Mjolnir pins freedesktop-sdk 26.08.4, which tracks systemd 261; policyref options are v262 | `include/versions.yml` in Mjolnir, FSDK 26.08.3 release notes, systemd-cryptenroll(1) |

## Implementation plan for the follow-up task

Order the units so each ends in a check that can run without Mjolnir changes.
Units 1 and 2 are Gram only. Unit 3 is Gram only for the command shape but the
real boot test needs the Mjolnir fixtures.

### Unit 1, config and validation

The files are `src/profile.zig`, `src/config.zig`, and `src/cli.zig`.

Add to `Profile`:

```zig
block_setup: []const u8 = "tpm2-luks",
signed_state: bool = false,
```

Set `block_setup = "direct"` and `signed_state = true` on Mjolnir. Leave
Muramasa at the defaults.

Add to `Config`:

```zig
tpm2_public_key: []const u8 = "",
state_unlock_key: []const u8 = "",
```

In `cli.zig`, load both with `config_mod.secret(allocator, io, env, value,
name)` using names `tpm2-pcr-public-key` and `state-unlock-key`.

In `config_mod.validate`, return `error.MissingPcrPublicKey` when
`profile.signed_state and encrypt and tpm2_public_key.len == 0`. Check that the
PEM starts with `-----BEGIN PUBLIC KEY-----` and reject otherwise. This is the
credential boundary check. Do not parse the key in Zig.

Run `zig build test`, which includes the fuzz and dry-run secret tests.

### Unit 2, plan and execution

The files are `src/plan.zig`, `src/execute.zig`, and `src/verify.zig`.

Add the action variant:

```zig
pub const EnrollState = struct {
    label: []const u8,
    state_label: []const u8,
    public_key_path: []const u8,
    unlock_key_path: []const u8,
};
```

Use `p.block_setup` in place of the hardcoded `"tpm2-luks"` at line 145 of
`src/plan.zig`. For Mjolnir with encryption, append these actions after the
bootc install action and before `persist_wifi`:

1. `write_file` label `write PCR public key credential`, path
   `/run/gram/tpm2-pcr-public-key.pem`, content `c.tpm2_public_key`, mode 0600.
2. `write_file` label `write state unlock key`, path
   `/run/gram/state-unlock-key`, content `c.state_unlock_key`, mode 0600.
3. `enroll_state` with the state label `MjolnirState` and those two paths.

In `execute.zig`, handle `.enroll_state` by calling
`findState(allocator, r, p.state_label)`. Fail with `StatePartitionNotFound`
when the label is absent and `signed_state` is true. Then run these commands in
order against the resolved device.

```sh
systemd-cryptenroll --recovery-key \
  --unlock-key-file=/run/gram/state-unlock-key \
  <state-device>

systemd-cryptenroll --wipe-slot=tpm2 \
  --tpm2-device=auto \
  --tpm2-pcrs=7 \
  --tpm2-public-key=/run/gram/tpm2-pcr-public-key.pem \
  --tpm2-public-key-pcrs=11 \
  --unlock-key-file=/run/gram/state-unlock-key \
  <state-device>
```

`--wipe-slot=tpm2` is correct for a fresh install and makes reruns converge to
one TPM2 slot. It is not correct for rotation, which is a separate operation.
The recovery key must be shown once to the operator and never written to the
install log or the dry-run log.

Extend `Verify` with `require_signed_pcr: bool`. When true, assert that
`systemd-cryptenroll <state-device>` lists a TPM2 slot and that the LUKS2 JSON
token records a public key fingerprint. The exact token field to assert needs
one cryptenroll run against the Mjolnir fixture to pin down.

Run `zig build test`, then run `scripts/check-dry-run.sh` after updating
`tests/golden/mjolnir.txt` and `tests/golden/muramasa.txt`. Dry-run goldens must
show the new `write_file` and `enroll_state` labels and must not contain the
credential bytes.

Run the enrollment action twice against the same LUKS device in a throwaway VM
to check idempotence. The second run must leave one TPM2 slot and one recovery
slot.

### Unit 3, swtpm harness

The files are `scripts/vm-install-test.sh`, a new `scripts/swtpm-pcr-test.sh`,
and new `tests/swtpm/` fixtures.

Start swtpm outside QEMU:

```sh
swtpm socket \
  --tpmstate dir="$WORK/swtpm" --tpm2 \
  --ctrl type=tcp,port=2322 --server type=tcp,port=2321 \
  --flags not-need-init,startup-clear &
```

Add to the QEMU command:

```sh
-chardev socket,id=chrtpm,host=127.0.0.1,port=2321 \
-tpmdev emulator,id=tpm0,chardev=chrtpm \
-device tpm-tis,tpmdev=tpm0
```

For Secure Boot, use an OVMF code file with secboot support and a per-VM copy
of the matching VARS file. Gram's ISO is unsigned, so the test must either sign
the ISO's boot artifacts with the test DB key or enroll the PCR policy in a
boot where Secure Boot is already on. Record which path the harness takes.

Keep the test script rerunnable and keyed on observed state, not on fixed sleep
durations. That follows the existing `system_powerdown` pattern in
`scripts/vm-install-test.sh`.

### swtpm test matrix

| # | Setup | Expected result | Gram alone? |
| --- | --- | --- | --- |
| 1 | SB on, Mjolnir public key credential present, state is LUKS after repart | Recovery slot and one TPM2 slot appear, token records the key fingerprint | Yes, with a LUKS fixture |
| 2 | Reboot into the same signed UKI | State unlocks with no recovery prompt | Needs Mjolnir UKI |
| 3 | Install a new UKI signed by the same key, reboot | State still unlocks. This is the regression in issue 9 | Needs Mjolnir UKI |
| 4 | Install a UKI signed by an unknown key, reboot | State does not unlock, recovery key works | Needs Mjolnir UKI |
| 5 | Boot with Secure Boot disabled after enrollment | State does not unlock because PCR 7 changed | Yes, with a PCR 7 fixture |
| 6 | Start install with no public key credential | Installer fails with `MissingPcrPublicKey` before writing any slot | Yes |
| 7 | Start install with a public key from a different RSA key pair | First boot fails to unlock. Gram cannot detect this without a published fingerprint | Partial, needs Mjolnir fingerprint |
| 8 | Apply a new signing key while retaining the old slot, boot both UKIs, then wipe the old slot | Both UKIs unlock during overlap, only the new one after wipe | Needs Mjolnir key pair |
| 9 | Wipe both TPM2 slots, reboot | Recovery key still unlocks | Yes |
| 10 | Run enrollment twice, reboot | One TPM2 slot, one recovery slot, state unlocks | Yes |

Rows 1, 5, 6, 9, and 10 can use a throwaway key pair and a synthetic LUKS
volume built in Gram. They prove plumbing, not vendor trust. Rows 2, 3, 4, 7,
and 8 need UKIs and signing keys from the Mjolnir release pipeline. A key pair
generated inside Gram cannot prove that an unknown vendor key is rejected.

### Unit 4, commit sequence

One commit per unit. Unit 1 lands with its tests. Unit 2 lands with updated
goldens. Unit 3 lands with the harness and the Gram-only matrix rows. Unit 4
lands after the Mjolnir fixtures exist and covers the Mjolnir-dependent rows.
Do not merge the enrollment code while the state volume in Mjolnir is
plaintext, because the plan would enroll against a device that does not exist.

## Blocked on the Mjolnir image repository

These items cannot be completed in Gram alone. Gram has no control over the
image build, the UKI sections, the repart definition, or the release keys.

1. `files/config/repart.d/20-mjolnir-state.conf` creates a btrfs partition with
   no `Encrypt=` setting. The state volume is plaintext today, so there is no
   LUKS2 device for `systemd-cryptenroll` to enroll. Mjolnir must add
   `Encrypt=yes` with a key file and document which credential supplies it.
   Gram's `--unlock-key-file` needs that same key.
2. `elements/uki/mjolnir-uki.bst` passes `--secureboot-private-key` and
   `--secureboot-certificate` to `bootc container ukify`. It passes no PCR
   signing key, so the UKI has no `.pcrsig` or `.pcrpkey` section. Mjolnir must
   add a separate RSA PCR key pair and pass `--pcr-private-key`,
   `--pcr-public-key`, and `--pcr-banks=sha256` to `ukify`. Keep the default
   policy reference to match Gram's enrollment.
3. `elements/uki/boot-keys.bst` and `scripts/gen-dev-keys.sh` generate only
   X.509 Secure Boot keys. Mjolnir must add PCR key generation, keep the
   private key in CI secrets, never commit it, and strip signing elements from
   runtime stacks.
4. `docs/PROVISIONING.md` and `scripts/make-credentials.py` must publish the
   PCR public key as `tpm2-pcr-public-key`, plus the state unlock key if
   repart uses one. Gram consumes both names.
5. Mjolnir must define and publish the rotation policy: new key pair per
   release or per incident, overlap window, and the numeric slot to wipe.
6. The swtpm fixtures for rows 2, 3, 4, and 8 must be built by the Mjolnir
   pipeline. Gram can build the harness but cannot mint a vendor signature.

## Related constraint, not changed here

Mjolnir's `docs/SECURITY.md` says no `--karg` may be passed at install because
the cmdline is baked into the signed UKI. Gram's `src/plan.zig` passes five
`--karg` values today, including `systemd.volatile=yes`. Kernel command line
overrides are measured into PCR 12, not PCR 11, so they do not break the
signed PCR 11 binding. They can still break the sealed root guarantee. That is
issue 4 territory and is out of scope here.
