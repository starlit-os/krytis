# Secure Boot Skills

## Signed UKI PCR changes do not affect FIDO2 or passphrase LUKS unlock

TPM PCR measurements (PCR 4 = boot manager, PCR 7 = secure boot policy, PCR 11 = UKI sections) are only consumed by **TPM-bound unseal operations**. krytis's two actual unlock paths ignore them entirely:

- **FIDO2** — LUKS2-token-plugin path (`attach_luks2_by_fido2_via_plugin()`, see `docs/skills/fido2.md`): challenge-response with the security key. No TPM involvement at any point.
- **Passphrase** — plain KDF against the LUKS header. Cryptographically independent of PCR state.

So enabling secure boot / switching to a signed UKI (which flips PCR 7 and changes PCR 4's extension sequence) cannot lock out a fleet that has **no TPM-bound enrollments**. Verified for krytis as of #312: zero TPM-bound volumes, no TPM kargs shipped, no TPM enrollment tooling in the image. The `tpm2-tss`/`tpm2-tools`/`tpm2-pkcs11` packages in `base-system.bst` are libraries, not enrollment paths — the population stays empty unless a user hand-runs `systemd-cryptenroll --tpm2-device`.

**Decision rule:** when a boot-chain change "breaks TPM PCRs," first enumerate which enrolled unlock mechanisms actually read those PCRs. If the answer is none, the PCR delta is a non-issue — don't build mitigations for a population of zero.

## Under a UKI, the LUKS regression risk is the cmdline bake, not PCRs

With a UKI the kernel cmdline is **frozen inside the signed PE** — `bootc kargs` and post-install `kargs.d` edits have no effect. `rd.luks.options=fido2-device=auto` (`files/bootc-config/30-fido2-luks.toml`) must be baked into `.cmdline` at seal time by `bootc container ukify`'s `get_kargs_in_root()`, or FIDO2 unlock silently regresses to passphrase fallback. Verify on every sealed build:

```bash
ukify inspect /boot/EFI/Linux/krytis.efi    # or: objdump -s -j .cmdline <uki>
```

…then confirm on real hardware: enroll via `mise fido2:enroll-luks`, reboot, expect key-touch unlock with no passphrase prompt.

## Don't cargo-cult travier's `systemd-tpm2-*` masks or `ukify --measure`

travier's `fedora-atomic-desktops-sealed` `uki.sh` uses `ukify --measure` and masks `systemd-tpm2-setup-early.service`, `systemd-tpm2-setup.service`, `systemd-pcrphase.service`, `systemd-pcrproduct.service`. Both are workload-specific, not defaults:

- `--measure` populates PCR 11 for TPM attestation/unlock flows. With no TPM-bound volumes it buys nothing and makes PCR 11 part of the boot contract a future TPM design must inherit. Re-evaluate inside a TPM-LUKS feature, where PCR selection (7+11 vs others) is designed as a whole.
- The masks work around specific hardware TPM hangs across a large Fedora Atomic fleet. Masking four units "just in case" — with no observed failures — is debt a future TPM feature has to unmask and debug.

**Escalation rule:** only mask if sealed-boot verification or real hardware shows a `systemd-tpm2-*`/`systemd-pcr*` unit failing or hanging (`systemctl --failed`, `journalctl -b -p err`). Then mask per travier's list and record the finding in the TPM-LUKS issue.

## `sbsign` ships as `sbsigntools-maybe.bst`, not `sbsigntools.bst`

Freedesktop SDK has no public `elements/components/sbsigntools.bst`. The real name is `sbsigntools-maybe.bst` — a `kind: stack` that conditionally depends on `components/_private/sbsigntools.bst` only when `target_arch` is in `["x86_64", "i686", "aarch64", "riscv64"]`. The `-maybe` suffix is a recurring freedesktop-sdk naming convention for arch-gated stacks over a `_private/` implementation element — grep `elements/components/*-maybe.bst` upstream before assuming a bare package name is the dependable path. krytis targets x86_64, so `sbsigntools-maybe.bst` resolves correctly.

## `files/boot-keys/` filenames are case-sensitive: `PK`/`KEK` upper, `db` lower

`mise/tasks/generate-keys` and `mise/tasks/pull-keys` both write `PK.key`/`PK.crt`, `KEK.key`/`KEK.crt`, `db.key`/`db.crt` — mixed case, not a uniform convention. Any task or Containerfile step that reads these files (e.g. `mise/tasks/seal-uki`'s `--secret src=` paths) must match this exact casing or silently miss the file on case-sensitive filesystems.

## `bootc container ukify` needs a separate rootfs, not the active build layer

`bootc container ukify --rootfs /` (the default) fails with `Computing composefs digest: Cannot operate on active root filesystem; mount separate target instead` when run in a single-stage `RUN` step. This is a deliberate guard in bootc (confirmed on v1.16.6) — composefs digest computation refuses to hash the currently-building, mutable overlay layer. `--allow-missing-verity` does **not** bypass this; the guard is unrelated to fs-verity support.

The fix is a two-stage Containerfile, matching the upstream pattern in [bootc's `Dockerfile.cfsuki`](https://github.com/bootc-dev/bootc/blob/main/Dockerfile.cfsuki) and the [Fedora bootc sealed-image docs](https://docs.fedoraproject.org/en-US/bootc/experimental-building-sealed/):

```dockerfile
FROM localhost/krytis-input:latest AS base
RUN bootc container lint

FROM base AS sealed
RUN --mount=type=bind,from=base,target=/target \
    bootc container ukify --rootfs /target -- --output /boot/EFI/Linux/krytis.efi ...
```

`sealed` starts as a copy of `base`'s filesystem (so `bootc container ukify`'s *output* still lands in its own writable layer), but `--mount=type=bind,from=base,target=/target` gives it a **separate**, already-completed, read-only view of the same content at `/target` to compute the digest against. A same-stage self bind-mount (`--mount=type=bind,from=base,target=/target` inside the stage literally named `base`, without a second stage) does **not** work — buildah/podman rejects it with `no stage or image found with that name` because the stage isn't a complete image yet while it's still being built. Two distinct, sequential stages are required.

Two more issues surface only after the rootfs fix, both worth checking on any future bootc/ukify version bump:

- **`bootc container ukify` needs `/var/tmp` to exist.** bootc images intentionally ship `/var` empty (populated by `systemd-tmpfiles` at boot, not baked into the image), so ukify's temp composefs repo creation fails with `Creating new temp composefs repo: No such file or directory` unless the `RUN` step does `mkdir -p /var/tmp` first.
- **The systemd-boot binary to sign is at `/usr/lib/systemd/boot/efi/systemd-bootx64.efi`, not `/boot/EFI/systemd/systemd-bootx64.efi`.** The latter path only exists on a target system after `bootctl install`/`bootc install` has populated the ESP — it's never present inside the container image itself. Sign the source path (`sbsign` needs a distinct output file, so sign to `.signed` and `mv` over the original) so the pre-signed binary is what gets installed later.

Verified end-to-end on real keys: `objcopy -O binary --only-section=.cmdline` on the resulting UKI showed `quiet splash rd.luks.options=fido2-device=auto composefs=<64-char digest>`, and `sbverify --cert db.crt` passed for both the UKI and the signed systemd-boot binary.

## Sealed images push under `:sealed` tags, never `:latest`

`mise run push --sealed` tags `localhost/krytis:sealed` as `${REGISTRY}:${VERSION}-sealed` and `${REGISTRY}:sealed` — distinct from the unsigned `${REGISTRY}:${VERSION}` / `${REGISTRY}:latest` tags the default (non-`--sealed`) push produces. A sealed/UKI image needs `bootc install --composefs-backend --boot=uki` on the target, which a plain bootc install doesn't do — silently reusing `:latest` for the sealed variant would mean anyone pulling `:latest` expecting the ordinary install path gets an image that can't be installed the same way. Keep the tag suffix whenever adding new push variants.

## `--squash-all` erases parent/layer provenance — use `.Created` as a content-identity proxy instead

Both `mise lint` and `mise run seal-uki` build the same `Containerfile` with `podman build --squash-all`. Squashing collapses every stage into one layer and drops `.Parent`/`.History` entries that would otherwise reference the `localhost/krytis-input:latest` digest each was built from — `podman inspect --format '{{.Parent}}'` on the result is empty, and `.RootFS.Layers` for `:latest`/`:sealed` share no prefix with `krytis-input`'s own layer list. So there is no queryable link back to "which `krytis-input` build produced this."

`mise run push --sealed` instead compares `podman inspect --format '{{.Created}}'` between `localhost/krytis:latest` and `localhost/krytis:sealed`, auto-running `seal-uki` when `:sealed` is missing or older. This works because podman build is content-addressed: rebuilding `:latest` from byte-identical inputs (same `krytis-input`, same `Containerfile`) reuses the existing image ID and its **original** `Created` timestamp — confirmed by rebuilding twice in a row and seeing an unchanged `Id`/`Created`. Only a genuine content change (new `krytis-input` build, edited `Containerfile`) produces a new image ID with a fresh, current `Created`. That's what makes the comparison a real staleness signal rather than "was the build command merely re-invoked" — don't swap it for wall-clock/`mise run` invocation tracking, which would false-positive on every no-op rebuild.

Scope note: this only tracks drift in `:latest`'s content (kernel, base image, etc.), not signing-key freshness — rotating `files/boot-keys/` without any other content change won't trigger an automatic re-seal.
