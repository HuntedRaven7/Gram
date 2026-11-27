# Issue 8 credential transport and join token freshness

This document closes the decision gate in issue 8 before code lands. Gram carries Mjolnir provisioning credentials into installed state. The open question is who supplies a join token that is still valid at first boot.

## Decision

Provisioning obtains a fresh token. Gram reads the supplied credentials and writes them into installed persistent state. Gram does not call Varlink and does not mint or refresh tokens.

The decision is resolved from available evidence. Reversing it requires a Mjolnir change, so that path stays out of scope for issue 8.

## Current change: Gram side only

This change stages a recovery copy of the six credentials into the `MjolnirState` partition at `etc/mjolnir/credentials/<name>` with mode 0600. It does not make a worker join on first boot, and it does not close issue 8.

The image-side gap remains: Mjolnir's units read credentials only from `$CREDENTIALS_DIRECTORY`, `/run/credentials/mjolnir/` and `/run/credentials/@system/`. There is no reader for a persisted path. Gram staging alone therefore does not supply a join token to `mjolnir-join.service`. A follow-up Mjolnir change must add `LoadCredential=` bindings that point at the persistent path before a staged token becomes the first boot source. Until then the persisted files are a recovery copy for an operator to consume.

## Evidence

Mjolnir `docs/PROVISIONING.md` lists the required credentials and says join credentials are required on workers and ignored on the control plane. Its first boot sequence has `mjolnir-join.service` run `kubeadm join` with the token.

Mjolnir `src/mjolnir.c` lines 123 to 146 implement `cmd_join`. It reads `role`, `join-token`, `ca-cert-hash` and `control-plane-endpoint` from `$CREDENTIALS_DIRECTORY` or `/run/credentials/mjolnir/`, falls back to `/run/credentials/@system/`, and execs `/usr/bin/kubeadm join`. It makes no Varlink call.

Mjolnir `plugins/console/src/fleet.c` implements `io.mjolnir.Fleet.RotateJoinToken`. It runs `/usr/bin/kubeadm token create --print-join-command`, accepts only `role=control-plane`, and returns a `joinCommand`. `plugins/console/README.md` marks `RotateJoinToken` as privileged.

Mjolnir `plugins/console/mission.json` step `step-07-token` tells the operator to call `varlinkctl call https://CONTROLPLANE:1031/ws/services/io.mjolnir.Fleet io.mjolnir.Fleet.RotateJoinToken '{}'`. Its description says to create a fresh bootstrap token and update the provisioning credential on new workers. The documented flow assigns minting to the operator and delivery to provisioning.

Mjolnir `scripts/make-credentials.py` builds the credential directory on the provisioning host. It writes files as 0600 in a 0700 directory and prints only credential names.

Mjolnir `docs/IMPERMANENCE.md` says `/run` and `/etc` are volatile and only an allowlist is reattached from the `MjolnirState` partition. A credential in `/run/credentials/@system/` cannot survive into installed state on its own.

Kubernetes `kubeadm token` reference says `kubeadm init` creates an initial token with a 24 hour TTL, `kubeadm token create --ttl` defaults to `24h0m0s`, and a token has the form `[a-z0-9]{6}.[a-z0-9]{16}`. The token value carries no expiry. Expiry is managed by `kubeadm token create --ttl` in the cluster, so Gram cannot judge freshness from the string it reads. This is inferred from the reference, which describes expiry as a property of the created token and not of the token format.

Gram `src/cli.zig` lines 110 to 113 read only `registry-user`, `registry-token`, `wifi-ssid` and `wifi-psk`. `src/execute.zig` already mounts the state partition at `/mnt/gram-state` for WiFi persistence.

## Options considered

### Refresh through Varlink at first boot

A worker would call the control plane Varlink API before `kubeadm join` and use the returned join command. This does not work with the documented surface.

The only token method creates a new token and is restricted to the control plane. Every worker that calls it would mint a new cluster token and could invalidate a token another worker is about to use. The method is privileged, and `plugins/console/README.md` tells operators to protect the client CA and audit calls.

The worker has no Varlink client credential. `varlink-httpd.tls.trust` is the CA the server uses to verify clients. `fleet-kubeconfig` is a Kubernetes service account kubeconfig used by `mjolnir-fleet publish`, not a TLS client certificate. No method exists that returns a token without creating one.

Gram runs from the live ISO at install time. The installed node has no Varlink endpoint until after its own boot. Gram cannot be the first boot Varlink caller even if a suitable method existed.

### Provisioning obtains the token later

Provisioning mints a token on the control plane shortly before first boot and passes it as the `join-token` credential. This matches `docs/PROVISIONING.md` and the mission runbook. Gram only transports and validates the value. We chose this option.

## Consequences

A worker joins only when provisioning supplies a token that is still valid at first boot. Mint it with `kubeadm token create --print-join-command` close to first boot. For installs that sit in staging, pass a longer `--ttl` when the token is created.

Gram validates token format. It cannot validate freshness, because the expiry is not in the token string. Gram records credential names and install time in its log. It never records a credential value.

A stale token makes `mjolnir-join.service` restart and fail. Recovery is an operator token rotation through `RotateJoinToken` followed by a new provisioning credential.

The persisted credentials are a recovery copy. At first boot the consuming units still read credentials from `$CREDENTIALS_DIRECTORY`, `/run/credentials/mjolnir/` or `/run/credentials/@system/`, as Mjolnir documents. Making the persisted copy the first boot source needs a Mjolnir unit change, such as `LoadCredential=` with a persistent path. That change is a follow-up, not part of issue 8. Gram does not add those bindings and the issue stays open.

## Implementation plan

### Credential registry

Use one table as the source of truth for name, consumer, requirement and validator. Do not scatter name checks across the config, plan and execute modules.

| Name | Consumer | Requirement | Destination file |
| --- | --- | --- | --- |
| `role` | `mjolnir-init`, `mjolnir-join`, fleet units | Required for the Mjolnir profile | `etc/mjolnir/credentials/role` |
| `join-token` | `mjolnir-join` | Required when role is `worker` | `etc/mjolnir/credentials/join-token` |
| `ca-cert-hash` | `mjolnir-join` | Required when role is `worker` | `etc/mjolnir/credentials/ca-cert-hash` |
| `control-plane-endpoint` | `mjolnir-join` | Required when role is `worker` | `etc/mjolnir/credentials/control-plane-endpoint` |
| `varlink-httpd.tls.trust` | `varlink-httpd` | Optional with a warning | `etc/mjolnir/credentials/varlink-httpd.tls.trust` |
| `fleet-kubeconfig` | `mjolnir-fleet-publish` | Optional with a warning | `etc/mjolnir/credentials/fleet-kubeconfig` |

Issue 8 names all six values as needed. Gram requires `role` and, for a worker, the join triple. It warns for the two management credentials because Mjolnir runs without them in a basic cluster. Muramasa keeps its own credential set. Read and write none of these names on the Muramasa profile path.

### Paths and modes

Read each name from the first existing file in this order: `$CREDENTIALS_DIRECTORY/<name>`, `/run/credentials/gram.service/<name>`, `/run/credentials/@system/<name>`. Trim trailing whitespace and the trailing newline. Accept no JSON keys and no CLI flags for these names, so a value cannot land in `install.json` inside the ISO.

Mount the state partition by label `MjolnirState` at `/mnt/gram-state`, reusing the path used by WiFi persistence. Write each credential to `/mnt/gram-state/<destination file>` from the registry table. After boot the same file is `/var/lib/mjolnir/etc/mjolnir/credentials/<name>` on the persistent state partition.

Create the credential directory with mode 0700 and owner `root:root`. Write each file with mode 0600 and owner `root:root`. `writeFile` in `src/execute.zig` sets the mode but does not set the owner, so add an explicit owner change and a `stat` check after the write. Do not write credential values to the live root, the image, the ISO squashfs, process arguments, or logs.

### Validation

Validate at credential ingestion and pass typed values to the plan. The plan then carries no validation branches.

- `role` is exactly `control-plane` or `worker`.
- `join-token` matches `[a-z0-9]{6}.[a-z0-9]{16}` as documented by `kubeadm token`.
- `ca-cert-hash` starts with `sha256:` followed by at least 32 hex characters, matching `make-credentials.py`. Warn when the hash is shorter than 64 hex characters, which is what kubeadm prints.
- `control-plane-endpoint` matches `^[^:\s]+:\d{1,5}$` and its port is in 1 through 65535, matching `make-credentials.py`.
- `varlink-httpd.tls.trust` contains a PEM BEGIN and END CERTIFICATE pair and is at most 65536 bytes.
- `fleet-kubeconfig` is at most 1048576 bytes, the read cap in `fleet.c`, and contains `apiVersion:`, `kind: Config`, `clusters:`, `contexts:` and `users:`.

Fail the install before the disk wipe when a required credential is missing or invalid. Name the credential in the error. Never print its value. An optional credential that is missing or invalid produces a warning and no file.

### Tests

Add a validator test for each row in the registry. Extend the dry run golden to print credential names only. Add an assertion that no credential value appears in any command argv or output. In the full install test, check mode 0600 and owner `root:root` on each persisted file after the mount is in place.
