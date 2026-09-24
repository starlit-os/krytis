# Secure Boot Skills

## Signed UKI PCR changes do not affect FIDO2 or passphrase LUKS unlock

TPM PCR measurements (PCR 4 = boot manager, PCR 7 = secure boot policy, PCR 11 = UKI sections) are only consumed by **TPM-bound unseal operations**. krytis's two actual unlock paths ignore them entirely:

- **FIDO2** — LUKS2-token-plugin path (`attach_luks2_by_fido2_via_plugin()`, see `docs/skills/fido2.md`): challenge-response with the security key. No TPM involvement at any point.
- **Passphrase** — plain KDF against the LUKS header. Cryptographically independent of PCR state.

So enabling secure boot / switching to a signed UKI (which flips PCR 7 and changes PCR 4's extension sequence) cannot lock out a fleet that has **no TPM-bound enrollments**. Verified for krytis as of #312: zero TPM-bound volumes, no TPM kargs shipped, no TPM enrollment tooling in the image. The `tpm2-tss`/`tpm2-tools`/`tpm2-pkcs11` packages in `base-system.bst` are libraries, not enrollment paths — the population stays empty unless a user hand-runs `systemd-cryptenroll --tpm2-device`.

**Decision rule:** when a boot-chain change "breaks TPM PCRs," first enumerate which enrolled unlock mechanisms actually read those PCRs. If the answer is none, the PCR delta is a non-issue — don't build mitigations for a population of zero.

## Under a UKI, the LUKS regression risk is what got frozen at seal time, not PCRs

With a UKI the kernel cmdline **and the initrd** are frozen inside the signed PE — `bootc kargs` and post-install `kargs.d` edits have no effect. Both halves of FIDO2 LUKS unlock are therefore seal-time decisions:

- **Non-root volumes** ride the cmdline: `rd.luks.options=fido2-device=auto` (`files/bootc-config/30-fido2-luks.toml`) is resolved into `.cmdline` at seal time by `bootc container ukify`'s `get_kargs_in_root()`.
- **The root volume ignores that karg entirely.** `systemd-gpt-auto-generator` creates the root's unit and builds its own option string — measured on hardware with the karg present on `/proc/cmdline` and no FIDO2 attempt in the log (#250). Root unlock comes from `elements/config/fido2-root-unlock.bst`'s `krytis-fido2-root-unlock.service` + `50-krytis-fido2-root.conf`, which `elements/core/initramfs.bst` names in `install_items+=` so they reach the **initrd** — and the initrd is frozen in the same signed PE. See `docs/skills/fido2.md` § `gpt-auto-generator` owns the root's crypt options, and only ever adds TPM2.

So a sealed build that drops either one regresses silently to a passphrase prompt, and neither can be repaired on the installed system. Verify both on every sealed build:

```bash
ukify inspect /boot/EFI/Linux/krytis.efi    # or: objdump -s -j .cmdline <uki>
lsinitrd /boot/EFI/Linux/krytis.efi | grep -e libfido2 -e krytis-fido2-root-unlock
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
`.auth` generation commands don't depend on `ukify` at all — test them directly against a built
`localhost/krytis:latest` (which has `sbsiglist` from `sbsigntools-maybe.bst` and
`sign-efi-sig-list` from `core/efitools.bst`, both via `elements/stacks/bootc.bst`) with real
test keys. This mirrors the Containerfile exactly, which is the point — a recipe that uses
different tools than the build is not a test of the build:

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
sbsiglist --owner "$GUID" --type x509 --output PK.esl PK.der
sbsiglist --owner "$GUID" --type x509 --output KEK.esl KEK.der
sbsiglist --owner "$GUID" --type x509 --output db.esl db.der
for ms in /ms-certs/*.der; do
    sbsiglist --owner "$GUID" --type x509 --output ms.esl "$ms" && cat ms.esl >> db.esl && rm ms.esl
done
sign-efi-sig-list -g "$GUID" -k /keys/PK.key -c /keys/PK.crt PK PK.esl auto/PK.auth
sign-efi-sig-list -g "$GUID" -k /keys/PK.key -c /keys/PK.crt KEK KEK.esl auto/KEK.auth
sign-efi-sig-list -g "$GUID" -k /keys/KEK.key -c /keys/KEK.crt db db.esl auto/db.auth
SCRIPT
```

Sanity-check the result from the host with `scripts/parse-efi-auth.py auto/db.auth`, which walks
the file and reports every entry's certificate subject, exiting non-zero on an empty list. Do
**not** reach for `sig-list-to-certs`: it was never reliable here (see the correction below) and
`core/efitools.bst` does not ship it.

Verified this way when the recipe was written: `PK.auth`/`KEK.auth`/`db.auth` all generate
without error, and the pre-signing `db.esl` carried exactly 3 X509 entries — krytis's own db
cert plus the 2 bundled Microsoft CAs — confirming the Microsoft-cert-bundling
loop concatenates into the same `db.esl` correctly. Run the same recipe today and the count
is **6**: `files/microsoft-uefi-certs/` has held all five Microsoft db CAs since #464. The
recipe covers PK/KEK/db only; `dbx.auth` goes through the same `sign-efi-sig-list` call in the
Containerfile, which also runs an `assert_esl` gate the recipe above predates. This does
**not** substitute for a full
`mise run seal-uki` + `sbverify` + firmware-enrollment run (still required before considering
the Containerfile change fully verified), but it does isolate "is my new shell logic correct"
from "does `ukify` work in this environment" when the two would otherwise be conflated by one
failing `RUN` step.

> **Correction (#438).** This section used to end: *"`sig-list-to-certs`'s own extracted `.der`
> files come out 0 bytes in this efitools version — a tool quirk, not a bug in the `.esl`; the
> header count printed to stderr is the reliable signal, not the output file sizes."*
>
> That was wrong, and it dismissed the exact evidence of a real defect. The `.der` files were
> 0 bytes because the signature lists genuinely **contained no certificates**:
> `cert-to-efi-sig-list` wants **PEM**, the Containerfile feeds it **DER**, and on wrong-format
> input it writes a well-formed empty list and exits 0. Every `.auth` krytis shipped enrolled an
> empty allow-list, so a machine that enrolled them turned Secure Boot on and then refused
> krytis's own signed loader. The three `X509 Header` blocks were three *empty* lists.
>
> **Reading rule this earns:** a count of structural headers is not evidence that the structures
> have contents. When a tool reports "N entries" and the extracted payloads are empty, believe the
> payloads. Byte sizes are the cheap check — an `EFI_SIGNATURE_LIST` holding one X509 cert is
> `28 + 16 + len(DER)` bytes, so anything near 44 is empty by construction.
>
> See § Every shipped `.auth` enrolled an empty allow-list — `cert-to-efi-sig-list` wants PEM
> below and #438 for the full root cause and the `sbsiglist`/`sbvarsign` fix.

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

### ukify's temp repo needs a `/var/tmp` that supports `O_TMPFILE`

`bootc container ukify` computes the digest by ingesting the whole rootfs into a
throwaway composefs repository, created with `tempfile::tempdir_in("/var/tmp")` —
**hardcoded, so `TMPDIR` is ignored** (bootc `crates/lib/src/bootc_composefs/digest.rs:28`;
objects land in `/var/tmp/.tmp<rand>/repo/objects`). Objects are ingested with
`O_TMPFILE`, which **fuse-overlayfs does not implement**:

```
Computing composefs digest: ... Creating object tmpfile:
  Opening temp file in objects directory: Operation not supported (os error 95)
```

This is invisible on a workstation whose podman uses native kernel overlayfs, and
fatal on a runner where rootless podman falls back to fuse-overlayfs — check with
`podman info --format '{{.Store.GraphDriverName}}'`. `mise/tasks/seal-uki` therefore
bind-mounts a host directory over `/var/tmp` for the ukify build (`podman build -v`),
and asserts `O_TMPFILE` works there before starting.

**Disk, not tmpfs.** The object store is a full copy of the rootfs — 6.5 GB measured
for krytis — so a tmpfs mount trades a build failure for an OOM. The scratch dir is
created under `/var/tmp` (on-disk on both CachyOS and the runners) rather than `/tmp`,
which is tmpfs on some hosts.

Upstream fixed this and krytis already carries the fix: composefs-rs `5a227a0` falls back
to a named tmpfile on `ENOTSUP` ([composefs-rs#368](https://github.com/composefs/composefs-rs/pull/368),
merged 2026-07-29; [bootc#2340](https://github.com/bootc-dev/bootc/issues/2340) closed
2026-08-04), `5a227a0` is an ancestor of composefs-rs `v0.9.2`, and `elements/core/bootc.bst`
pins bootc `v1.16.14` against exactly that `v0.9.2`. The `/var/tmp` bind-mount stays anyway —
see the correction below: #528 showed the failure is not purely an "does this filesystem
support `O_TMPFILE`" question, so the bind-mount is now an unconditional invariant rather
than a workaround waiting to be dropped.

> **Correction/extension (#528).** *"This is invisible on a workstation whose podman
> uses native kernel overlayfs"* is not the whole picture. `bootc container
> compute-composefs-digest` — the same primitive, invoked standalone by
> `mise/tasks/verify-composefs-digest` rather than as part of `ukify` — hit the
> identical `Operation not supported (os error 95)` on this project's own workstation
> (podman 5.4.2, confirmed native `overlay` driver, not fuse-overlayfs) when run
> against a locally-built `localhost/krytis:sealed` carrying **bootc 1.16.6**, in the
> same session where it succeeded against the currently published
> `ghcr.io/starlit-os/krytis:sealed`, which happens to carry **bootc 1.16.7** — same
> host, same overlay driver, different result, isolated by bisecting on `bootc
> --version` inside each image. So the O_TMPFILE gap is not purely a
> fuse-overlayfs-vs-native-overlayfs question; it also depends on which bootc build
> `${IMAGE}` itself carries, in a way that isn't pinned or asserted anywhere. The only
> reliable invariant is the fix already applied to `ukify`'s own phase: **always**
> bind-mount a host directory pre-verified for `O_TMPFILE` over `/var/tmp` for any
> container that runs `bootc container ukify` or `bootc container
> compute-composefs-digest`, never trust the container's own default `/var/tmp`
> regardless of how the host's graph driver looks from the outside.
> `mise/tasks/verify-composefs-digest` does this the same way `mise/tasks/seal-uki`
> does for its own `UKI_TMP`: `mktemp -d -p /var/tmp`, assert `O_TMPFILE` there, then
> `-v <dir>:/var/tmp` on the `podman run` that executes the digest computation.

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

`mise/tasks/seal-uki` implements this as its `[1/3]`/`[2/3]` steps (`[3/3]` is the digest verification below). `localhost/krytis:sealed-base` is a legitimate, kept intermediate artifact (not cleaned up) — it's the stable reference the digest was computed against, and rebuilding it before phase 2 would risk a fresh, non-matching squash pass.

`Containerfile.seal-uki` hardcodes the `localhost/krytis:sealed-base` reference in its `--mount=type=bind,from=...` (rather than parameterizing via `ARG`) because ARG-expansion inside `--mount=from=` wasn't verified against the pinned podman/buildah version — if the intermediate tag name ever needs to change, update both `FROM`/`--mount=from=` occurrences together.

`mise/tasks/lint`'s unsigned build still uses a single `--squash-all` pass with no phase split — that's fine there because the unsigned image has no baked digest to invalidate in the first place.

### Verifying the baked digest against an already-published image, no rebuild, no root

#528 asked for exactly this check, and `mise/tasks/verify-composefs-digest` is it: after the
two-phase
build, confirm the digest baked into the UKI's `.cmdline` still matches the committed
image, without rebuilding (a rebuild can produce a *different* correct digest and prove
nothing — see the empirical procedure above). The by-hand procedure below is what the task
automates; it was verified end-to-end against the **then-published**
`ghcr.io/starlit-os/krytis:sealed` during the #528 investigation, which found no mismatch:

```bash
# 1. Extract the baked digest — no ukify/objcopy needed, .cmdline is a plain string
#    inside the PE, and its own format (128 lowercase hex chars, SHA-512) is specific
#    enough that a raw byte-scan of the extracted UKI is safe:
CID=$(podman create ghcr.io/starlit-os/krytis:sealed true)
podman cp "${CID}:/boot/EFI/Linux/krytis.efi" /tmp/krytis.efi
podman rm -f "${CID}"
grep -aoE 'composefs=[0-9a-f]{128}' /tmp/krytis.efi

# 2. Recompute against the COMMITTED image — bootc container compute-composefs-digest
#    is the lower-level primitive `bootc container ukify` calls internally (hidden from
#    --help, present since bootc 1.16.x). Run it from inside the image itself (which
#    already carries a matching bootc) against a read-only view of that same image:
podman run --rm \
    --mount type=image,src=ghcr.io/starlit-os/krytis:sealed,target=/target,rw=false \
    ghcr.io/starlit-os/krytis:sealed \
    bootc container compute-composefs-digest /target
```

The two outputs matched byte-for-byte on the 2026-08-09 published image.

`--mount type=image` (podman core since ~2.2, unrelated to the `--mount=type=bind,from=`
Containerfile directive used elsewhere in this doc) is the load-bearing choice over the
`podman mount`/`podman unshare` pairing used in the
original by-hand procedure: on this project's rootless podman (5.4.2, `overlay` graph
driver), `podman image mount` only makes its merged directory visible **inside** the
`podman unshare` mount namespace that created it — a sibling `podman run` outside that
namespace sees an empty directory at the same host path. `--mount type=image` sidesteps
the whole namespace question: podman resolves and mounts the source image for the target
container directly, no separate `unshare`/`mount`/`umount` lifecycle to get wrong, and it
is still a genuine read-only OCI-derived view of the committed image, not a rebuild.

`mise/tasks/verify-composefs-digest` (#528) automates exactly these two steps and is
now `mise/tasks/seal-uki`'s `[3/3]` phase — reach for the by-hand version above only
when debugging the task itself or checking an image outside the seal-uki flow (e.g.
a pulled `ghcr.io/starlit-os/krytis:sealed`, as this section's own verification was
done).




## Sealed images push under `:sealed` tags, never `:latest`

`mise run push --sealed` tags `localhost/krytis:sealed` as `${REGISTRY}:${VERSION}-sealed` and `${REGISTRY}:sealed` — distinct from the unsigned `${REGISTRY}:${VERSION}` / `${REGISTRY}:latest` tags the default (non-`--sealed`) push produces.

A sealed/UKI image is installed differently from an unsigned one, but **not** via a flag the installer has to know about: bootc **auto-detects** the UKI in the image and switches to the composefs backend itself — *"Whenever the container image has a UKI, bootc automatically selects the composefs backend during installation"* — so the installer only ever supplies `--composefs-backend` and `--bootloader systemd`. There is **no `--boot=uki` flag**; earlier revisions of this section claimed one, copied from a Fedora doc reference that has since been debunked. Verified against the authoritative `bootc install to-filesystem` man page, whose complete flag set is `--source-imgref`, `--target-imgref`, `--bootloader {grub,grub-cc,systemd,none}`, `--composefs-backend`, `--allow-missing-verity`, `--uki-addon`, plus the disk/selinux/karg flags.

The consequence for tagging is unchanged, and it is the point of this section: silently reusing `:latest` for the sealed variant would hand anyone pulling `:latest` an image whose boot chain only verifies against enrolled keys, when they expected the ordinary one. Keep the tag suffix whenever adding new push variants — and note the same discipline now extends to the ISO (`mise run build-iso --sealed` embeds `…/krytis:sealed` and writes `krytis-live-sealed.iso`, never overwriting the unsigned artifact's name).

## `--squash-all` erases parent/layer provenance — use `.Created` as a content-identity proxy instead

`mise lint` builds `Containerfile` with a single `podman build --squash-all` pass for the unsigned `:latest` image. `mise run seal-uki` also ends up squashed (see § `--composefs-backend` requires a single layer above) but via two separate squash passes across two Containerfiles, not one — the *order* matters there (squash the rootfs-prep stage first, bake the digest against that, squash again for the final image), not just whether squashing happens. Either way, squashing collapses every stage into one layer and drops `.Parent`/`.History` entries that would otherwise reference the `localhost/krytis-input:latest` digest each was built from — `podman inspect --format '{{.Parent}}'` on the result is empty, and `.RootFS.Layers` for `:latest`/`:sealed` share no prefix with `krytis-input`'s own layer list. So there is no queryable link back to "which `krytis-input` build produced this."

`mise run push --sealed` instead compares each image's `.Created` between `localhost/krytis:latest` and `localhost/krytis:sealed`, auto-running `seal-uki` when `:sealed` is missing or older. The comparison itself lives in `scripts/ensure-sealed-image.sh`, shared with `mise run build-iso --sealed`. This works because podman build is content-addressed: rebuilding `:latest` from byte-identical inputs (same `krytis-input`, same `Containerfile`) reuses the existing image ID and its **original** `Created` timestamp — confirmed by rebuilding twice in a row and seeing an unchanged `Id`/`Created`. Only a genuine content change (new `krytis-input` build, edited `Containerfile`) produces a new image ID with a fresh, current `Created`. That's what makes the comparison a real staleness signal rather than "was the build command merely re-invoked" — don't swap it for wall-clock/`mise run` invocation tracking, which would false-positive on every no-op rebuild.

Scope note: this only tracks drift in `:latest`'s content (kernel, base image, etc.), not signing-key freshness — rotating `files/boot-keys/` without any other content change won't trigger an automatic re-seal.

**Read that timestamp out of `--format json`, not `--format '{{.Created}}'`.** The
template renders Go's `time.String()` (`2026-08-02 16:21:14.125718274 +0000 UTC`),
which GNU `date -d` rejects outright — while the uutils `date` on the usual
workstation accepts it, so the breakage only ever appears in CI. `scripts/ensure-sealed-image.sh`
parses the JSON (RFC3339Nano) instead. Details: `docs/skills/mise.md` § `/usr/bin/date`
here is uutils, not GNU.

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

### `--secure` picks the tag; booting `:latest` under enforcement is the negative test

`--secure` verifies signatures, and only `mise run seal-uki`'s
`localhost/krytis:sealed` is signed — `localhost/krytis:latest` from `mise build`
has no signed systemd-boot and no UKI at all (`/boot/EFI/Linux/krytis.efi` exists
only in the sealed image). `boot-test` therefore resolves `--image` from the
mode: `:sealed` under `--secure`, `:latest` otherwise, and `:latest` again under
`--secure --expect-fail`, whose whole purpose is to watch the firmware refuse the
unsigned build. Name `--image` explicitly only to override that.

The default is computed in the script, not in the `#USAGE` annotation: a
`default=` there is indistinguishable from the user typing the same value, so
`usage_image` could not tell "unset" from "explicitly `:latest`".

Boot the wrong tag under enforcement — which is what happened before the default
existed (#417/#425) — and the firmware refuses the disk before systemd-boot
prints anything. The entire log is:

```
BdsDxe: failed to load Boot0002 "UEFI Misc Device" from PciRoot(0x0)/Pci(0x3,0x0):
        Access Denied -- rejected probably by Secure Boot
>>Start PXE over IPv4.  PXE-E16: No valid offer received.
BdsDxe: No bootable option or device was found.
```

Note `failed to **load**` and the absence of any `../src/boot/boot.c` line: this
is one stage earlier than the UKI rejection above — BDS refusing the bootloader
itself. Read that shape as "wrong tag", not as a regression in the change under
test. `boot-test` now also refuses up front, before the privileged install, when
an explicitly named image has no UKI or does not exist locally.

Five deliberate combinations, only the first four positive:

| Command | Asserts |
|---|---|
| `mise run boot-test` | the image boots and is healthy — the right check for anything that isn't about the boot chain |
| `mise run seal-uki && mise run boot-test --secure` | the *signed* image boots under enforcement, against a varstore `generate-ovmf-vars` pre-enrolled with the same certificates `db.auth` carries |
| `mise run seal-uki && mise run enroll-test` | the image's **own** `.auth` files enrol into a setup-mode firmware and the loader still verifies afterwards — a different question, and the one #438 answered wrongly for months |
| `mise run selfenroll-test` | the same, on a **real installed disk** rather than a synthetic ESP — ESP layout, UKI, composefs and first-boot units included — ending in a healthy system with `Secure Boot: enabled (user)` |
| `mise run boot-test --secure --expect-fail` | secure boot rejects the unsigned image |

The second and third are not substitutes. `boot-test --secure` boots keys that
virt-fw-vars already placed, so it never touches `loader/keys/auto`; `enroll-test`
makes the firmware do the enrolling from the image's own files. An image can pass
one and fail the other — that is exactly what #438 was.

Note that a systemd rebuild changes systemd-boot and systemd-stub, so any
element change touching systemd invalidates an existing `:sealed` image — rerun
`mise run seal-uki` rather than booting the stale one.

## A sealed ISO payload must be embedded byte-identically, and its ref must move too

`mise run build-iso --sealed` embeds `localhost/krytis:sealed` as the live ISO's
offline install payload. Two non-obvious requirements, both of which otherwise
produce late, confusing failures:

**1. Byte identity.** The payload injector — `live/iso-tools/payload-prep.sh`, in this
repo — writes `/usr/lib/bootc/install/00-defaults.toml` (a `root-mount-spec`) into every
payload, adds `/etc/containers/storage.conf` on the composefs backend krytis uses, and
re-commits the result twice with `buildah commit --squash` (the second pass only to
relabel `ostree.final-diffid` on the squashed layer). The krytis *image* ships neither
file — the live environment's own copies come from `live/src/configure-live-krytis.sh`
and are a separate thing — and each `buildah run`/`commit` round trip can bump `/tmp` and
`/var/tmp` mtimes, the same, and only, discrepancy that broke the UKI digest before
(§ `bootc container ukify` must run in a throwaway stage). Any of the three invalidates
the `composefs=` digest baked into the UKI's frozen cmdline, and `bootc install` then
aborts with `The UKI has the wrong composefs= parameter (is 'sha512:X', should be
sha512:Y')`. `PAYLOAD_SEALED=1` makes the pipeline pass the payload through untouched.
Skipping only the `00-defaults.toml` injection — which is what issue #371 originally
scoped — is **not** enough.

`PAYLOAD_SEALED=1` is honoured twice over, because both halves of the pipeline live here:
`scripts/iso-sd-boot.sh` skips the prep step entirely, and `payload-prep.sh` — which
`iso-sd-boot.sh` otherwise runs on the host, or inside the `ISO_TOOLS_IMAGE` container on
a krytis host with no buildah — still passes the archive through untouched if it is
invoked directly. Squashfs assembly is `iso-sd-boot.sh`'s own inline
`_ns_build_squashfs`; there is exactly one copy of the injection in this repo. (Upstream
dakota-iso carried a duplicate in a second entry point, `scripts/build-live-squashfs.sh`,
that krytis never reached and deliberately did not port — do not go looking for it here.)

**2. `targetImgref`, not just the store key.** `live/src/configure-live-krytis.sh` bakes
one ref into four `recipe.json` fields: `imgref`, `targetImgref`, `image`,
`local_imgref`. Change only the embedded *content* and the install succeeds while
`targetImgref` still points at `…/krytis:latest` — so the first `bootc upgrade` on
the freshly sealed system pulls the **unsigned** image, overwrites the signed UKI
and signed systemd-boot, and the enrolled firmware refuses to boot it. Change only
`payload_ref` and `local_imgref` no longer resolves in the offline store, failing
the install immediately. `PAYLOAD_REF` moves both together; `build-iso --sealed`
sets it to `ghcr.io/starlit-os/krytis:sealed`. Verify on an installed system with
`bootc status --json | jq '.spec.image.image'`.

`iso-sd-boot.sh` ignores env vars it does not know, so an engine that had drifted from its
caller would silently produce a *broken* sealed ISO instead of failing. That is now
structural rather than policed: caller (`mise/tasks/build-iso`) and engine
(`scripts/iso-sd-boot.sh`, `live/iso-tools/payload-prep.sh`) are versioned together in one
repo. `build-iso` still refuses up front, before the expensive build, when the image it is
asked to embed does not exist locally — the same "fail before the expensive step, not
during it" discipline as `boot-test`'s UKI presence check.

### Assert the embed on the finished ISO, not inside the pipeline

Once the sealed path is a pass-through, byte identity is true *by construction*, so
asserting it inside `scripts/iso-sd-boot.sh` would be tautological.
`mise run verify-iso-payload` reads the **finished ISO** instead, which is the only
place that proves the whole chain (`podman save` → oci-archive → `skopeo copy` → VFS
store → squashfs → ISO) preserved the image. It also catches the "wrong tag embedded"
class of bug that already bit once (#417/#425). `build-iso --sealed` runs it
automatically.

The invariant is image-ID equality, established empirically:

- a VFS containers-storage records `vfs-images/images.json` as a list of
  `{"id": …, "names": [...]}`, where `id` is exactly
  `podman inspect <tag> --format '{{.Id}}'` (the config digest, no `sha256:` prefix);
- `podman save --format oci-archive` round-trips both the config digest and the
  layer diff_id unchanged for krytis's images (they are already OCI-format, so no
  manifest conversion happens). Checked against `:sealed`: ID `0b00a10aad1a…`,
  diff_id `e2ae30e0f0ac…`, identical before and after the archive round trip.

Byte identity is a *stronger* claim than digest equality, which is what makes it
the right assertion — and it needs no privileged mount and no digest recomputation.
The authoritative digest check is `bootc install` itself, which recomputes and
names both digests in its error; the QEMU install test is therefore the end-to-end
digest proof, and this gate is the cheap regression net in front of it.

Reading the payload out of the ISO needs neither root nor a 5GB extract: walk the
ISO 9660 directory records to find `LiveOS/squashfs.img`'s extent, then
`unsquashfs -offset <lba*2048> -cat <iso> <path>`. File data in an ISO is
contiguous — including across the multi-extent records `-iso-level 3` uses for
files over 4GB — so the first record's extent is the start of the squashfs. Assert
the `hsqs` magic at the computed offset so a layout change fails loudly instead of
as a confusing unsquashfs error. `xorriso` is not on the krytis host at all — `build-iso`
routes it and `implantisomd5` through this repo's own `live/iso-tools/` container via
`ISO_TOOLS_IMAGE` — so an `-osirrox` extract would be both slower and less portable here.

## A sealed system's boot cannot be judged from the serial console

`console=ttyS0` is a kernel argument, and a UKI's kernel arguments are frozen
inside the signed PE — injecting one is exactly what sealing prevents. So every
harness that decides "did it boot?" by grepping the guest's serial log for
`Reached target Graphical Interface` is structurally unable to pass a sealed
system. Krytis's own phase-4 verdict does precisely that: `mise/tasks/iso-verify-boot`
polls the installed guest's serial log for `Reached target …Graphical` / `Multi-User` /
`login:` (with `--expect-fail` inverting it into a grep for the firmware's rejection
line), and `scripts/iso-install-fisherman.sh` patches `console=tty0 console=ttyS0` into
the BLS type-1 entries to make that output exist at all — a path a sealed system does not
boot through. Pointed at a sealed install it reported a five-minute timeout for a system
that was in fact completely healthy.

What a *successful* enforced sealed boot looks like on serial — all of it:

```
BdsDxe: loading Boot0002 "UEFI Misc Device" from PciRoot(0x0)/Pci(0x2,0x0)
BdsDxe: starting Boot0002 "UEFI Misc Device" from PciRoot(0x0)/Pci(0x2,0x0)
systemd-boot@0x101300000 260.2
systemd-stub@0x14df91000 260.2
```

Read it as evidence, not silence. `BdsDxe: starting` (rather than
`failed to load … Access Denied`) means the firmware accepted the signed
systemd-boot against the enrolled db; `systemd-stub@…` appearing after
`systemd-boot@…` means systemd-boot chain-loaded the UKI and its Authenticode
signature verified — a bad signature stops at
`Error loading EFI binary …: Access denied` instead. Everything after that point
goes to tty0 and is invisible. **"Nothing after `systemd-stub@`" means "we cannot
see the boot", never "the boot failed."**

The verdict has to come from a channel that needs no kernel argument.
`mise run boot-test --reuse-disk <disk> --secure` is that channel and is why
`mise run iso-install-test` stops `iso-e2e-test` at `--install-only` and takes the
verdict itself instead of using phase 4: boot-test provisions sshd, an authorized
key and a diagnostics probe as **SMBIOS type-11 systemd credentials**, which
systemd consumes with no cmdline involvement, then asserts health over SSH. The
same mechanism is what makes the negative test honest — the firmware's own
rejection line *does* reach serial, so `--expect-fail` asserts on that and reports
INCONCLUSIVE for a merely silent disk.

Corollary for any future sealed-boot tooling: prefer SMBIOS credentials over
kargs for anything a test needs to inject. Kargs are a signing-time decision;
credentials are a runtime one.

## Every shipped `.auth` enrolled an empty allow-list — `cert-to-efi-sig-list` wants PEM

Root-caused in #438 (found via #371). Boot a freshly installed sealed system against
a firmware
whose varstore is in **setup mode** (a blank OVMF varstore — i.e. a machine that
has never had keys) and systemd-boot does what #309 designed it to do:

```
BdsDxe: starting Boot0002 "UEFI Misc Device" …
Enrolling secure boot keys from directory: \loader\keys\auto
Custom Secure Boot keys successfully enrolled, rebooting the system now!
BdsDxe: failed to load Boot0002 "UEFI Misc Device" …: Access Denied -- rejected probably by Secure Boot
```

It enrolls krytis's own PK/KEK/db and then the firmware refuses krytis's own
signed bootloader. Reproduced on both the non-SMM and the proper
`OVMF_CODE_4M.secboot.fd` + `smm=on` + pflash-`secure=on` configuration, so it is
not the varstore-protection mistake it first looks like.

**Root cause: the `.auth` files contain no certificates at all.** `Containerfile`
converts each PEM cert to DER and feeds the DER to `cert-to-efi-sig-list`, but that
tool takes **PEM** (its own usage line says so). Given DER it finds no certificate,
writes a well-formed *empty* `EFI_SIGNATURE_LIST`, and **exits 0**;
`sign-efi-sig-list` then signs the empty payload perfectly validly. The firmware
accepts the writes, leaves setup mode, enables Secure Boot — with an empty
allow-list, so nothing verifies, including our own correctly signed loader.
`sbverify --cert db.crt` passes on both `systemd-bootx64.efi` and `krytis.efi`; the
boot chain's signing was never the problem.

Same DER input to both tools, in the image:

```
cert-to-efi-sig-list db.der out.esl   ->   44 bytes   # ListSize 0x2c, SigSize 0x10, no cert
sbsiglist --owner "$GUID" --type x509 --output out.esl db.der
                                      -> 1255 bytes   # 28 + 16 + 1211
```

**Size is the cheap tell.** One X509 cert in a signature list is `28 + 16 + len(DER)`
bytes. Anything near 44 is empty by construction. Post-enrollment varstores:

| varstore | PK | KEK | db |
|---|---|---|---|
| `.ovmf-vars-secure.fd` before this fix (virt-fw-vars, krytis's cert only) | 1254 | 1263 | 1255 |
| enrolled from the shipped `.auth` files | 44 | 44 | **132** (three empty lists) |
| enrolled from `sbsiglist` output, when db held krytis + two MS CAs | 1254 | 1263 | **4353** |
| **current** — krytis + all five Microsoft db CAs (#464) | 1254 | 1263 | **8891** |

Two consequences beyond the boot failure. #309's "db.auth includes Microsoft's
well-known CA certs" was never actually met (the loop concatenated three *empty*
lists) — it is now. And `boot-test --secure` had been verifying against a **narrower
db than any real machine gets**: `generate-ovmf-vars` baked krytis's cert alone
(1255 bytes) while an enrolling machine ends up with 4353. It proved strictly less
than it appeared to, which is part of why this went unnoticed.

`generate-ovmf-vars` now adds `files/microsoft-uefi-certs/*.der` in the same order
the Containerfile does, so the test varstore and the shipped `db.auth` hold the same
certificates. It also refuses to finish when they disagree — it extracts `db.auth`
from `localhost/krytis:sealed` and compares payload sizes, so "what we test" cannot
silently drift from "what we ship" again:

```
==> OVMF vars: .ovmf-vars-secure.fd (db: 8891 bytes)
==> Matches localhost/krytis:sealed's db.auth (8891 bytes)
```

Both sides glob `files/microsoft-uefi-certs/*.der`, so changing that set moves the
number in both places at once — it went 4353 → 8891 when #464 added the three
Microsoft CAs we had been omitting, with no code change on either side.

Widening db does not weaken the negative test — verified rather than assumed, since
a bigger allow-list could plausibly have made a rejection stop happening. An
unsigned `systemd-bootx64.efi` (mtools-copied over the ESP's signed one) is still
refused with `Access Denied` against the 4353-byte db. The Microsoft CAs authorise
Microsoft-signed binaries, not ours.

**Fix (landed): use each toolkit for the half it gets right.** The signature *lists*
come from sbsigntools' `sbsiglist`, which takes DER natively and cannot silently
produce an empty list. The *signatures* stay with efitools' `sign-efi-sig-list`,
which was never the broken half — and must stay, because sbsigntools' `sbvarsign`
writes the `EFI_TIME` month straight from a 0-based `tm_mon`:

```
sbvarsign          -> 2026-07-02 11:10:15     # built on 2026-08-02
sign-efi-sig-list  -> 2026-08-02 11:10:46     # same moment, correct
```

An August build stamped July is survivable; a **January** build would be stamped
month 0, which is not a valid `EFI_TIME`, and UEFI compares these timestamps for
authenticated-variable rollback protection — so a key rotation could be refused by
the firmware for reasons that look nothing like a date bug. Swapping both halves to
sbsigntools (the obvious "use one toolkit" cleanup) reintroduces this. Don't.

Feeding PEM to efitools also produces a correct list (verified — identical
4353-byte ESL), but it inverts every conversion in that `RUN` block and keeps a tool
that silently no-ops on wrong-format input.

### efitools is krytis-vendored since fdsdk 26.08 (#305)

The paragraph above says `sign-efi-sig-list` "must stay". freedesktop-sdk disagreed:
commit `b39e7194` ("Remove EFI elements", 2026-08-17, first shipped in
`freedesktop-sdk-26.08rc.1`) deleted, from **its own tree**, `components/efitools.bst`,
`efitools-bin.bst`,
`efitools-bin-maybe.bst`, `efitools-efi.bst` and `include/efitools.yml` outright — no
rename, no replacement, they just dropped it from their own
`vm/boot/efi-secure/deps.bst`. `components/perl-slurp.bst` went with it.

krytis carries it now: **`elements/core/efitools.bst`**, pinned to the same
`v1.9.2-4-gb988d20a` ref fdsdk used, wired into `stacks/bootc.bst` where the junction
element used to be. Nothing about the Containerfile changed.

Two things to know if you touch it:

- **Only `sign-efi-sig-list` is built and shipped.** fdsdk's element built the whole
  `all` target — nine signed EFI images, PK/KEK/DB key material, man pages — then
  deleted the EFI half again on install. That is what dragged in `gnu-efi`,
  `help2man`, generated boot keys and perl `File::Slurp`. krytis builds the single
  binary it calls. `cert-to-efi-sig-list` and friends are deliberately absent; the
  empty-signature-list footgun documented above cannot be re-introduced by someone
  reaching for a tool that happens to be on the image.
- **`gnu-efi` is still a build-dep**, which is not obvious: `sign-efi-sig-list.c`
  includes `<efi.h>` for the `EFI_SIGNATURE_LIST` and `EFI_TIME` layouts it writes.
  Without it the compile dies at `fatal error: efi.h: No such file or directory`,
  even though nothing here produces an EFI image.

Verified after vendoring, on the built artifact — the month is the whole point:

```
$ sign-efi-sig-list -c t.crt -k t.key PK empty.esl out.auth   # 2026-08-25 14:57:44
$ od -An -tu1 -N16 out.auth
 234   7   8  25  14  57  44   0   0   0   0   0   0   0   0   0
   └─year 2026─┘  └8┘ └25┘                                        # month 8, not 7
```

If upstream efitools ever goes away too, the exit is not `sbvarsign` — it is patching
`sbvarsign`'s `tm_mon` off-by-one, or moving `.auth` generation to `virt-fw-vars`,
which krytis already trusts for OVMF varstores but does not ship in the image.

Two gates now stand behind this, because a silent empty list is exactly the kind of
thing that ships:

- **Build time.** `assert_esl` in `Containerfile` reads the `SignatureSize` field at
  offset 24 of each list and fails the build when it is 16 (no certificate). Also
  `scripts/parse-efi-auth.py <file.auth>` walks any `.auth` and reports every
  entry's certificate subject, exiting non-zero on an empty one.
- **Runtime.** `mise run enroll-test` boots the mechanism in isolation (below) and
  asserts the firmware trusts the loader *after* enrolling the image's own keys.
  8 seconds. This is the gate #309 never had.

### `secure-boot-enroll manual` works — but not on the first boot after install

An earlier revision of this section claimed `manual` "does not prevent it". That was
wrong. Measured in isolation, varying only the ESP's `loader.conf`:

| `loader.conf` | auto-enrolls in a VM? |
|---|---|
| `secure-boot-enroll manual` + `timeout 0` | no |
| `secure-boot-enroll manual` + `timeout 5` | no |
| `secure-boot-enroll off` | no |
| **no `loader.conf` at all** | **yes** |

So the setting is honoured; the problem is *when* krytis has it.
`elements/config/secureboot-loader-conf.bst` appends the line from a first-boot
oneshot, which by definition runs **after** systemd-boot has already decided. The
very first boot of a fresh install therefore sees no setting and falls back to
systemd-boot's default `secure-boot-enroll=if-safe` — which auto-enrols inside a VM
(recognised as "safe") and does nothing on real hardware. From the second boot on,
`manual` governs.

**Decision (#444, option 3): accept and document — not going to be fixed.**
Consequence for real hardware: none — `if-safe` never auto-enrols there, so the
user still gets the intended manual prompt, on the first boot exactly as on every
later one. Consequence in a VM: a fresh install silently enrols krytis's own keys
on the first boot and comes up enforcing — this is what makes
`mise run selfenroll-test` pass without a manual key-selection step, and is
treated as convenient test behaviour, not a defect to chase.

Two other directions were weighed and rejected. A systemd compile-time default for
`secure-boot-enroll` was the cleanest candidate if it existed, but it would still
be a build-time workaround for the same "value not on the ESP at handoff" gap, not
a real fix, and was never confirmed to exist in the shipped systemd version.
Writing `loader.conf` at install time needs a bootc install-time hook, which does
not exist today. Either would require nontrivial new plumbing to change a state
that already matches the design intent on the only surface that ships to users —
real hardware. Not planned.

**Testing trap this creates.** `boot-test` always boots a *copy* and never mutates
the source disk, so an install disk stays a first-boot disk no matter how many times
you test with it — every probe re-runs the `if-safe` path. If you read
`/boot/loader/loader.conf` from inside such a guest you will see
`secure-boot-enroll manual` and conclude it was in force during that boot. It was
not: the oneshot wrote it seconds earlier, long after the firmware handed off.

**Why no existing test caught it:** `mise run boot-test --secure` pre-enrolls the
varstore with virt-fw-vars, which bypasses `loader/keys/auto` completely. Nothing
in the repo had ever put a freshly installed disk in front of a *blank* varstore
until an ISO install did. Any future work on enrollment must test the
setup-mode-first-boot path explicitly; a passing `boot-test --secure` says nothing
about it.

**Test enrollment in isolation — no bootc, no ISO, no UKI.** `mise run enroll-test`
does this; the shape is worth knowing because it is how any future enrollment
question should be asked. A full install to reach one firmware decision is a
15-minute round trip, but the whole mechanism is an ESP with a signed loader and
three files, so build exactly that and boot it against a pristine varstore. QEMU's
VVFAT (`fat:rw:<dir>`) builds the filesystem from a directory, so no image, no
partitioning and no root are involved:

```bash
mkdir -p esp/EFI/BOOT esp/loader/keys/auto
cp systemd-bootx64.efi esp/EFI/BOOT/BOOTX64.EFI      # from the sealed image
cp {PK,KEK,db}.auth   esp/loader/keys/auto/
cp /usr/share/edk2/ovmf/OVMF_VARS_4M.secboot.fd vars.fd   # pristine = setup mode
qemu-system-x86_64 -enable-kvm -m 1024 -machine q35,smm=on \
  -global driver=cfi.pflash01,property=secure,value=on \
  -drive if=pflash,format=raw,readonly=on,file=/usr/share/edk2/ovmf/OVMF_CODE_4M.secboot.fd \
  -drive if=pflash,format=raw,file=vars.fd \
  -drive file=fat:rw:esp,format=raw,if=virtio \
  -display none -serial file:serial.log -daemonize -pidfile qemu.pid
```

8 seconds later the verdict is in `serial.log`, and it is unambiguous: a second
`BdsDxe: starting` + `systemd-boot@` after the enrollment reboot means the firmware
now trusts the loader; `failed to load … Access Denied` means it does not; and one
`systemd-boot@` with no rejection at all is INCONCLUSIVE — that first boot happened
in setup mode and enforced nothing. Then dump what actually landed with
`virt-fw-vars --input vars.fd --print` and check the db size against the table
above. Vary one input at a time — this is how #438 was isolated to the `.auth`
files rather than the disk, the installer, or the firmware configuration.

**Booting a sealed disk with enforcement genuinely off.** Not a workaround for the
bug any more — it is the only way to express "a machine that will never enrol",
because a setup-mode VM now *correctly* enrols krytis's keys on first boot and comes
up enforcing (and "keys enrolled, Secure Boot off" is not a state OVMF can
represent: it derives Secure Boot from PK presence, and `virt-fw-vars` has no
disable switch). So remove the enrollment trigger from the *copy* you boot, never
from the payload. The ESP is FAT, so this needs no root (same mtools technique as
the UKI byte-flip test above):

```bash
export MTOOLS_SKIP_CHECK=1
# ESP offset: first GPT partition entry's starting LBA × 512
OFF=$(python3 -c 'f=open("disk.raw","rb");f.seek(1024+32);print(int.from_bytes(f.read(8),"little")*512)')
mdeltree -i "disk.raw@@${OFF}" ::/loader/keys
```

With the trigger gone the same disk boots to `running` with `bootctl status`
reporting `Secure Boot: disabled (setup)` — which is how #371 demonstrated that a
sealed payload is still a valid non-secure-boot image.

For the opposite case — the fixed keys enrolling for real — no fixture surgery is
needed at all. Install from the sealed ISO, boot the disk against a pristine
`OVMF_VARS_4M.secboot.fd` with `smm=on`, and the whole chain runs itself:

```
BdsDxe: starting Boot0002 …            <- setup mode, nothing enforced yet
systemd-boot@0x101300000 260.2
Enrolling secure boot keys from directory: \loader\keys\auto
Custom Secure Boot keys successfully enrolled, rebooting the system now!
BdsDxe: starting Boot0002 …            <- now enforcing, and it still starts
systemd-boot@0x101300000 260.2
systemd-stub@0x14df91000 260.2         <- UKI signature verified too
```

In-guest afterwards: `is-system-running` → `running`, `bootctl status` →
`Secure Boot: enabled (user)`, no failed units, `bootc status` booted image
`ghcr.io/starlit-os/krytis:sealed`. That is the acceptance criterion #438 was filed
for, on the real artifact rather than the isolated ESP.

## Microsoft's dbx has to be re-signed with our KEK — and unioned with ours


krytis enrols Microsoft's revocation list, but not Microsoft's copy of it. Their
published dbx is already an `EFI_VARIABLE_AUTHENTICATION_2` **signed by
Microsoft's KEK** — and krytis enrols only its own KEK plus Microsoft's *db* CAs.
Firmware accepts a `dbx` update only when a KEK it trusts signed it, so shipping
their file unchanged would produce an update every krytis machine rejects.


`mise run fetch-microsoft-dbx` therefore keeps the *payload* and discards their
signature. Both halves are committed, because both are used and they are not
interchangeable:


| File | What it is | Consumed by |
|---|---|---|
| `dbx.bin` | the upstream artifact verbatim, Microsoft-KEK-signed | `generate-ovmf-vars --set-dbx` (virt-fw-vars reads the `EFI_TIME` header; a bare ESL makes it fail with `month must be in 1..12`) |
| `dbx.esl` | the union of that payload, the previously committed list, and `files/dbx-extra-revocations/*.der` | `sign-efi-sig-list dbx …` in the Containerfile, re-signed with krytis's KEK |

`dbx.esl` legitimately revokes **more** than `dbx.bin` — it is not extracted from it.
That is deliberate; see below.


Source note: the list lived at `uefi.org/revocationlistfile` for years (those URLs now
403), moved to `github.com/microsoft/secureboot_objects` in 2024, and moved *again*
inside that repo in 2026-09 — `PostSignedObjects/DBX/amd64/DBXUpdate.bin` 404s. The
tree now carries `SignedByKEK2011/` (a `dbx_x64_Legacy` cumulative list plus one file
per later addition) and `SignedByKEK2023/dbx_x64.efiauth2` (a single cumulative list,
exactly Legacy + those increments). The task fetches the KEK2023 one because it is the
superset; which KEK signed it does not matter to us, since the signature is discarded
and the payload re-signed. Upstream's `PostSignedObjects/Readme.md` still documents the
pre-move layout, so read the tree, not the docs, when this breaks again.

**An upstream refresh can revoke *less*, and a binary diff will not tell you.** That
move did not only relocate the file, it pruned it: 443 hashes in what #446 committed,
289 in the new Legacy list, 297 in the union of every dbx artifact Microsoft now
publishes. Every list is plain SHA256 (`SignatureSize` 48) — no SVN or SHA384 list
hiding the difference. Taking upstream verbatim would have un-revoked 154 hashes: the
#446 staleness hazard running backwards.

So `fetch-microsoft-dbx` merges rather than replaces (#755):

- `dbx.esl` = committed entries, in their existing order, plus upstream entries not
  already present. Regression is impossible by construction; the task re-parses what it
  is about to write and aborts if any committed digest is missing.
- Append-only ordering means an unchanged upstream reproduces the file byte for byte —
  the task is a no-op, not a reshuffle — and a real update reads as an append.
- It prints `upstream no longer publishes N of the M committed revocation(s)` whenever
  upstream shrinks, so a prune is visible in the job log instead of buried in a blob.
- A signature list type it cannot merge (SVN, SHA384) is fatal, never silently dropped:
  `Microsoft has changed the dbx format … update the task deliberately`.


**`dbx` entries are hashes, not certificates.** A revocation is 16 bytes of owner GUID
plus a 32-byte SHA-256 digest, so `SignatureSize` is 48 and there is nothing for
openssl to parse. Any tooling that assumes X509 will report a `dbx` as corrupt —
`scripts/parse-efi-auth.py` handles both. Note which mode you want: the default treats
its argument as an `.auth` and reports per list (`dbx.bin` → `291 revoked sha256 image
hash(es)`), while `--count-esl` reads a bare signature list and prints a total entry
count (`dbx.esl` → `447` = 445 hashes + the 2 local x509 revocations). Pointing the
default mode at a bare `.esl` reports `would enrol nothing` — that is the wrong mode,
not a corrupt file. The CI job uses `--count-esl` for the PR title.
The build-time `assert_esl` check happens to
work unchanged, since 48 > 16.


**systemd-boot does enrol `dbx` from `loader/keys/auto`** — verified, not assumed, and
the reason `enroll-test` now asserts it. A missing `dbx` fails nothing on its own; the
machine just quietly trusts every binary Microsoft has revoked, which is why the
assertion exists rather than a printed line someone might skim past.


**#757 tightened that assertion from a byte-count floor to a byte-exact match.**
`>=100 bytes` is "non-empty", not "complete": the #755 union-split regression this
guard exists to catch — dropping 154 of 445 hashes — still leaves ~14KB, two orders of
magnitude past the floor. `sign-efi-sig-list` wraps its input ESL as the payload
verbatim (no re-sort, no dedupe), so the enrolled `dbx` blob is provably byte-identical
to `files/microsoft-uefi-certs/dbx.esl` when nothing has gone wrong — `enroll-test` now
asserts exactly that (23304 bytes, 447 entries as of #755). That also catches drift no
other check would: a bad merge, a hand-edited `dbx.esl`, or a Containerfile change that
signs the wrong file. `generate-ovmf-vars`'s upstream-`dbx.bin`-fallback warning was
hardened the same way — it now runs `--count-esl` on both files and prints the live
delta instead of a number hardcoded at #502 (`2` certificates) that had silently gone
two orders of magnitude stale by the time #755 shrank `dbx.bin` by another 154 hashes.


Staleness is the live hazard: Microsoft adds revocations on their own schedule.
`track-bst-sources.yml`'s `track-microsoft-dbx` job refreshes the pair and opens a PR
titled with the delta. Re-run `mise run seal-uki && mise run enroll-test` before
merging one — the digest changes, so the sealed image must be rebuilt anyway.

## A sealed UKI's frozen cmdline breaks every installer that expects to inject kargs

A UKI measures and signs its kernel cmdline *inside* the image. Nothing at install time
can add to it — no `rd.luks.uuid=`, no `rd.luks.name=`, no `root=`. That is the point of
a UKI, and it quietly invalidates the standard way installers configure an encrypted
root.

This shipped as an unbootable LUKS install (#473): plymouth splash, no passphrase
prompt, ~90 s on `dev-gpt-auto-root.device`, then emergency mode — unreachable, because
bootc images ship root locked and `sulogin` refuses. The splash is what made it look
like a prompt problem; it was a *device* timeout.

The chain, and why each link is load-bearing:

1. `hostonly=no` means no `/etc/crypttab` in the initrd, so nothing enumerates volumes.
2. The cmdline is frozen, so `rd.luks.uuid=`/`rd.luks.name=` cannot be supplied either.
3. dracut's catch-all rule that unlocks *any* LUKS device is gated behind `rd.auto=1`
   (`70crypt/parse-crypt.sh`: `elif getargbool 0 rd.auto`), which krytis does not set.
4. That leaves `systemd-gpt-auto-generator` as the only mechanism — and it only
   recognises a root partition carrying the **discoverable** GUID
   `4f68bce3-e8cd-4db1-96e7-fbcaf984b709`, not the generic `0fc63daf-…`.

Historically fisherman typed the encrypted root generically and relied on injecting
`rd.luks.name=<UUID>=root` into BLS entries, which a UKI install never receives. Its own
retag to the discoverable GUID existed but was gated `&& !hasEncryption` — behind a LUKS
mapping the raw partition is not what is mounted, so the post-install unmount/rewrite/
remount could not run there at all.

**Fixed upstream 2026-09-19 in [tuna-os/fisherman#219](https://github.com/tuna-os/fisherman/pull/219)**
(merged in PR #224, released as v0.4.0): the type is written when the partition table is
created, which covers both layouts, and it is architecture-aware — the old constant was
x86-64 only, so an aarch64 install would have been tagged with a GUID the generator
ignores there. krytis proposed the same partition-time approach first, as two copies of one
branch: [tuna-os/fisherman#72](https://github.com/tuna-os/fisherman/pull/72), closed
2026-08-06, and [projectbluefin/fisherman#19](https://github.com/projectbluefin/fisherman/pull/19),
which stayed open until 2026-09-24 because its base repo had been archived in the meantime —
see `docs/skills/workflow.md` § Archiving an upstream freezes its PRs. Both are superseded.

### The encrypted-root GUID fix, and where it actually comes from

The merge is necessary but not sufficient: krytis never builds fisherman: it gets the
binary out of the bootc-installer flatpak (`configure-live-krytis.sh` symlinks it out of
the app dir), and that flatpak builds fisherman from a git submodule. So the fix reaches
krytis only when three things line up:

1. fisherman `dev` carries it — merged 2026-09-19 02:38Z;
2. `tuna-os/bootc-installer` bumps its `fisherman` submodule past that commit — the
   release krytis installs pins `982282b` (2026-09-19 07:39Z);
3. `live/src/install-flatpaks.sh` downloads from *that* repo.

Step 3 was the real blocker. The script pointed at `projectbluefin/bootc-installer` with
`tuna-os/tuna-installer` as fallback, and **both are archived** — development moved back
to the tuna-os org. Their newest bundles are 2026-08-01 and 2026-05-08, so an ISO built
the day after the upstream fix landed still shipped the bug. Extracting both bundles
shows it directly:

```bash
ostree init --repo=repo --mode=archive-z2
flatpak build-import-bundle repo org.bootcinstaller.Installer.flatpak
ostree --repo=repo checkout -U app/org.bootcinstaller.Installer/x86_64/master co
strings -a co/files/bin/fisherman | grep -c 'type=%s, name="root"'
# archived projectbluefin bundle → 0  (only the old literal type=linux)
# tuna-os bundle                 → 1  (arch-aware, written at partition time)
```

**Generalise: when an upstream fix "lands", check the delivery vehicle, not just the
merge.** A green upstream PR says nothing about which binary our ISO embeds.

Process note, because the sequence is confusing in the history: #72 was opened
uninvited, closed, then reopened on request. Publishing to a repository this project
does not own needs an explicit instruction — AGENTS.md § Third-party repositories.

**Operator fix for a machine installed before the fix shipped** — metadata only, data
untouched. New installs from an ISO built after 2026-09-19 do not need it:

```bash
sudo sfdisk --part-type /dev/nvme0n1 3 4f68bce3-e8cd-4db1-96e7-fbcaf984b709
```

`mise run luks-boot-test` guards it, and its `--generic-guid` arm reproduces the failure
so a pass cannot be luck.

**The general rule:** when an installer configures anything by writing kernel arguments,
a sealed UKI does not receive that configuration. Prefer mechanisms that live on disk
and are discoverable — partition GUIDs, LUKS2 tokens, credentials — over anything that
has to reach the kernel through a bootloader entry.
