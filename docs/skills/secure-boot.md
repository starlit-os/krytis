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

## `bootc container ukify`'s composefs digest needs `O_TMPFILE` — fails on some nested/WSL2 podman setups

`bootc container ukify --rootfs /target` can fail with:

```
error: Building UKI: Computing composefs digest: Reading container root: Reading container root:
Ensuring object from file descriptor: Ensuring object from reader: Creating object tmpfile:
Opening temp file in objects directory: Operation not supported (os error 95)
```

This is `composefs-rs` trying to `open(O_TMPFILE)` in its temp objects directory and getting
`ENOTSUP` — confirmed unrelated to `--allow-missing-verity`, `BUILDAH_ISOLATION=chroot` (tried,
no effect), or anything in the `SEAL_SECURE_BOOT` Containerfile stage itself. Reproduced on a
WSL2 host running podman with the `overlay` graph driver on an ext4-backed virtual disk — the
nested container's overlay upper dir apparently doesn't support `O_TMPFILE` in this stack, even
though the host ext4 filesystem does. Not reproduced on bare-metal Linux CI runners.

**Workaround for verifying `.auth`/signing logic changes without a working `ukify` step:** the
`.auth` generation commands (`cert-to-efi-sig-list`/`sign-efi-sig-list`) don't depend on `ukify`
at all — test them directly against a built `localhost/krytis:latest` (which already has
`efitools` from `elements/stacks/bootc.bst`) with real test keys:

```bash
podman run --rm -i \
    -v "$(pwd)/files/boot-keys:/keys:ro" \
    -v "$(pwd)/files/microsoft-uefi-certs:/ms-certs:ro" \
    localhost/krytis:latest bash -s <<'SCRIPT'
set -ex
mkdir -p /work/auto && cd /work
GUID=$(cat /proc/sys/kernel/random/uuid)
openssl x509 -in /keys/PK.crt -outform DER -out PK.der
openssl x509 -in /keys/KEK.crt -outform DER -out KEK.der
openssl x509 -in /keys/db.crt -outform DER -out db.der
cert-to-efi-sig-list PK.der PK.esl
cert-to-efi-sig-list KEK.der KEK.esl
cert-to-efi-sig-list db.der db.esl
for ms in /ms-certs/*.der; do cert-to-efi-sig-list "$ms" ms.esl && cat ms.esl >> db.esl && rm ms.esl; done
sign-efi-sig-list -g "$GUID" -k /keys/PK.key -c /keys/PK.crt PK PK.esl auto/PK.auth
sign-efi-sig-list -g "$GUID" -k /keys/PK.key -c /keys/PK.crt KEK KEK.esl auto/KEK.auth
sign-efi-sig-list -g "$GUID" -k /keys/KEK.key -c /keys/KEK.crt db db.esl auto/db.auth
sig-list-to-certs db.esl db-check   # sanity: should print one "X509 Header" block per bundled cert
SCRIPT
```

Verified this way: `PK.auth`/`KEK.auth`/`db.auth` all generate without error, and
`sig-list-to-certs` against `db.esl` (before signing) printed exactly 3 `X509 Header` blocks —
krytis's own db cert plus the 2 bundled Microsoft CAs — confirming the Microsoft-cert-bundling
loop concatenates into the same `db.esl` correctly. This does **not** substitute for a full
`mise run seal-uki` + `sbverify` + firmware-enrollment run (still required before considering
the Containerfile change fully verified), but it does isolate "is my new shell logic correct"
from "does `ukify` work in this environment" when the two would otherwise be conflated by one
failing `RUN` step.

`sig-list-to-certs`'s own extracted `.der` files come out 0 bytes in this efitools version —
a tool quirk, not a bug in the `.esl`; the header count (`X509 Header sls=N`) printed to stderr
is the reliable signal, not the output file sizes.
## `bootc container ukify` must run in a throwaway stage, never the final image

`bootc install to-disk` recomputes the composefs digest over **whatever image it is installing** and verifies it against the `composefs=` parameter baked into the UKI's `.cmdline` section. If they disagree, install fails late with:

```
error: Installing to disk: Setting up composefs boot: Setting up UKI boot:
  Writing krytis.efi to ESP: The UKI has the wrong composefs= parameter
  (is 'sha512:<uki-baked>', should be sha512:<install-time>)
```

**A three-stage Containerfile (`sealed` → `uki` where `uki` runs `ukify` against a bind-mount of `sealed`, and `uki` itself becomes the final image) is NOT sufficient** — this looked correct (all rootfs mutations happen before ukify runs, ukify's own output goes only to `/boot/`, which is excluded from the composefs payload) but still produced a digest mismatch every time. The real cause is subtler than stage ordering:

`bootc container ukify`'s digest computation internally creates its own scratch composefs repo via `tempfile::tempdir_in("/var/tmp")` (see bootc's `crates/lib/src/bootc_composefs/digest.rs`) — a real directory create-then-delete in **the calling container's own `/var/tmp`**, which bumps that directory's mtime as a side effect of merely running the tool, separate from whatever `--rootfs` path it's hashing. If `ukify` runs inside the stage that becomes the final image, that mtime bump gets baked into the pushed image's own `/var/tmp` — but the digest was computed by reading `/target` (a bind-mount of `sealed`, a *different*, unperturbed reference), which never saw that bump. The final image and the digest baked into its own UKI permanently disagree.

**Confirmed by direct comparison, not just inference:** built the same content two ways — (a) `ukify --rootfs /target` running live, inside a build stage that becomes the final image, vs. (b) `podman mount` on the *already-committed* image (no rebuild, just a plain OCI-derived view) — and diffed the `--write-dumpfile-to` manifests. Every line matched except two: the mtimes of `/tmp` and `/var/tmp`. That is the entire discrepancy, and it reproduces regardless of how carefully the Containerfile's stage *ordering* is arranged, because the mutation is a side effect of running `ukify` itself, not of anything the Containerfile explicitly writes.

**The actual fix** — a **four-stage** Containerfile, matching bootc's own upstream pattern (`contrib/packaging/seal-uki` runs in a throwaway `tools`-derived stage; `contrib/packaging/finalize-uki`, run in the real final stage, only `cp`'s the resulting file — see `tmt/tests/Dockerfile.upgrade` for the full worked example):

```dockerfile
FROM base AS sealed                  # stage 2: prepare the FINAL rootfs contents
RUN ... sbsign ... mv ...            # sign systemd-boot, write any rootfs files

FROM sealed AS uki-builder           # stage 3: THROWAWAY — never becomes final
ARG SEAL_SECURE_BOOT=false
RUN --mount=type=bind,from=sealed,target=/target \
    bootc container ukify --rootfs /target -- --output /out/krytis.efi
    # uki-builder's OWN /var/tmp gets perturbed here — doesn't matter, this
    # stage is discarded.

FROM sealed                          # stage 4: the actual final image
ARG SEAL_SECURE_BOOT=false
RUN --mount=type=bind,from=uki-builder,target=/uki-out \
    mkdir -p /boot/EFI/Linux && cp /uki-out/out/krytis.efi /boot/EFI/Linux/krytis.efi
    # A plain file copy never touches /tmp or /var/tmp, so this stage's rootfs
    # stays byte-identical (modulo the new file) to what uki-builder hashed.
```

Verified end-to-end: rebuilt with this structure, extracted the baked digest from the resulting `:sealed` image, then independently recomputed the digest via `podman mount` on that same already-committed image (not a rebuild) — the two matched exactly.

## `--composefs-backend` requires a single layer, but squashing breaks the UKI digest — reconcile with a two-phase build

Two independent, contradictory requirements collide in a sealed build:

1. **`bootc install --composefs-backend` requires a single-layer image.** A multi-layer image fails during `bootc install to-disk` with `Pulling image into composefs repository: Unexpected EOF in splitstream` — this exactly matches a constraint dakota already hit and documented (`docs/design/composefs-chunkah.md`: "Multi-layer output breaks composefs xattr injection; see dakota#841"). Removing `--squash-all` (the fix from the previous section, on its own) produces a correct digest but an image that can never install via `--composefs-backend`.
2. **Squashing (`--squash-all`) breaks the digest** (previous section): it rewrites/normalizes file metadata — confirmed specifically to be `/tmp` and `/var/tmp` mtimes — across the whole image at commit time. If squashing happens *after* `ukify` bakes the digest, the pushed image's own metadata diverges from what's baked in its UKI, and install fails with "The UKI has the wrong composefs= parameter" — regardless of the throwaway-stage fix.

Single-layer is non-negotiable (required for install to work at all) and squashing-after-baking is impossible (breaks the digest) — so the resolution is to **squash before baking**: produce a stable, already-squashed single-layer reference first, compute the UKI digest against *that* (not the pre-squash multi-layer build), then squash the final combined result too. Verified this reconciles both constraints simultaneously: the resulting image has exactly 1 layer *and* the baked digest matches a `podman mount`-based post-commit recompute.

This needs **two separate `podman build` invocations** — a single Containerfile can't squash one intermediate stage while leaving others alone; `--squash-all` always applies to the whole build's result:

```bash
# Phase 1: build + squash just the rootfs-prep stage into a stable reference
podman build --squash-all --target sealed -t localhost/krytis:sealed-base \
    --secret id=db_key,src=... [...] -f Containerfile .

# Phase 2 (separate Containerfile.seal-uki): compute the UKI against
# sealed-base (throwaway uki-builder stage, per the previous section), then
# build the real final image FROM sealed-base + cp the .efi in, and squash
# THIS too
podman build --squash-all -t localhost/krytis:sealed \
    --secret id=db_key,src=... -f Containerfile.seal-uki .
```

`mise/tasks/seal-uki` implements this as its two `[1/2]`/`[2/2]` steps. `localhost/krytis:sealed-base` is a legitimate, kept intermediate artifact (not cleaned up) — it's the stable reference the digest was computed against, and rebuilding it before phase 2 would risk a fresh, non-matching squash pass.

`Containerfile.seal-uki` hardcodes the `localhost/krytis:sealed-base` reference in its `--mount=type=bind,from=...` (rather than parameterizing via `ARG`) because ARG-expansion inside `--mount=from=` wasn't verified against the pinned podman/buildah version — if the intermediate tag name ever needs to change, update both `FROM`/`--mount=from=` occurrences together.

`mise/tasks/lint`'s unsigned build still uses a single `--squash-all` pass with no phase split — that's fine there because the unsigned image has no baked digest to invalidate in the first place.



## Sealed images push under `:sealed` tags, never `:latest`

`mise run push --sealed` tags `localhost/krytis:sealed` as `${REGISTRY}:${VERSION}-sealed` and `${REGISTRY}:sealed` — distinct from the unsigned `${REGISTRY}:${VERSION}` / `${REGISTRY}:latest` tags the default (non-`--sealed`) push produces. A sealed/UKI image needs `bootc install --composefs-backend --boot=uki` on the target, which a plain bootc install doesn't do — silently reusing `:latest` for the sealed variant would mean anyone pulling `:latest` expecting the ordinary install path gets an image that can't be installed the same way. Keep the tag suffix whenever adding new push variants.

## `--squash-all` erases parent/layer provenance — use `.Created` as a content-identity proxy instead

`mise lint` builds `Containerfile` with a single `podman build --squash-all` pass for the unsigned `:latest` image. `mise run seal-uki` also ends up squashed (see § `--composefs-backend` requires a single layer above) but via two separate squash passes across two Containerfiles, not one — the *order* matters there (squash the rootfs-prep stage first, bake the digest against that, squash again for the final image), not just whether squashing happens. Either way, squashing collapses every stage into one layer and drops `.Parent`/`.History` entries that would otherwise reference the `localhost/krytis-input:latest` digest each was built from — `podman inspect --format '{{.Parent}}'` on the result is empty, and `.RootFS.Layers` for `:latest`/`:sealed` share no prefix with `krytis-input`'s own layer list. So there is no queryable link back to "which `krytis-input` build produced this."

`mise run push --sealed` instead compares `podman inspect --format '{{.Created}}'` between `localhost/krytis:latest` and `localhost/krytis:sealed`, auto-running `seal-uki` when `:sealed` is missing or older. This works because podman build is content-addressed: rebuilding `:latest` from byte-identical inputs (same `krytis-input`, same `Containerfile`) reuses the existing image ID and its **original** `Created` timestamp — confirmed by rebuilding twice in a row and seeing an unchanged `Id`/`Created`. Only a genuine content change (new `krytis-input` build, edited `Containerfile`) produces a new image ID with a fresh, current `Created`. That's what makes the comparison a real staleness signal rather than "was the build command merely re-invoked" — don't swap it for wall-clock/`mise run` invocation tracking, which would false-positive on every no-op rebuild.

Scope note: this only tracks drift in `:latest`'s content (kernel, base image, etc.), not signing-key freshness — rotating `files/boot-keys/` without any other content change won't trigger an automatic re-seal.

## A negative test must assert the *rejection*, not just the absence of a boot

`boot-test --expect-fail` originally concluded "secure boot rejected it" from
"SSH never answered". That passes for the wrong reason on any image that fails to
boot for an unrelated cause — a missing UKI, a bad initramfs, a broken kargs
change — so it could never distinguish enforcement from breakage.

Both the loader and the firmware announce a signature rejection on the serial
console, so assert on that instead. Verified by booting a correctly-signed disk
with **one byte flipped inside the UKI**:

```
../src/boot/boot.c:2820@call_image_start: Error loading EFI binary \EFI\Linux\bootc\...efi: Access denied
BdsDxe: failed to start Boot0002 "UEFI Misc Device" from PciRoot(0x0)/Pci(0x3,0x0): Access Denied
BdsDxe: No bootable option or device was found.
```

The first line is systemd-boot refusing to chain a UKI whose Authenticode
signature no longer verifies; the second is EDK2's BDS. An **unsigned bootloader**
is refused by BDS the same way, one stage earlier. `boot-test` greps for
`[Aa]ccess [Dd]enied|Security Violation` and reports **INCONCLUSIVE** (exit 1)
when SSH is down but no such line appears — a silent disk proves nothing.

Contrast the two ways to produce a negative case:

| Method | Isolates the signature? |
|---|---|
| Flip one byte inside the signed UKI on the ESP | **Yes** — the signature is the only variable, so a rejection can only be a signature rejection |
| Install a different, unsigned image (`krytis:latest`) | No — an unsigned bootloader *should* be refused, but any other boot failure in that image looks identical |

The byte flip needs no root: the ESP is FAT, so `mtools` can read and rewrite the
UKI in place inside the raw disk image at the partition offset.

```bash
export MTOOLS_SKIP_CHECK=1
OFF=2097152   # ESP starts at sector 4096
UKI="::/EFI/Linux/bootc/bootc_composefs-<digest>.efi"
mcopy -n -i "disk.raw@@${OFF}" "$UKI" /tmp/uki.efi
python3 -c "import pathlib;p=pathlib.Path('/tmp/uki.efi');d=bytearray(p.read_bytes());d[len(d)//2]^=0xFF;p.write_bytes(d)"
mcopy -o -i "disk.raw@@${OFF}" /tmp/uki.efi "$UKI"
```

Combine with `--reuse-disk` to run the whole negative test unprivileged. Budget
~8 minutes: the firmware retries every boot entry, including a PXE attempt, before
giving up.
