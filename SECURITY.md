# Security policy

## Supported versions

Gram is pre-release. Only the latest commit on `main` receives fixes.

## Reporting a vulnerability

Use GitHub's private vulnerability reporting on this repository. Do not open a public issue for a security problem.

Include the affected commit, the impact, and a reproduction. A report that touches the installer should name the image profile and the install command that runs.

## Secrets

The installer reads registry credentials and WiFi keys from systemd credentials before it reads the JSON config. It passes registry tokens through `--password-stdin` and keeps WiFi keys out of argv. Dry-run output must never contain a password hash, WiFi key, or registry token. `tests.zig` checks that rule.

The ISO is unsigned. The target image supplies the signed UKI. Secure Boot key enrollment stays a hardware step for the operator.

## Dependency updates

Renovate updates the base image digest, the pinned zigzag release, and the minimum Zig version. A zigzag update needs a regenerated package hash in `build.zig.zon`.
