# Secure Boot + Unified Kernel Image (UKI)

Tracking epic: #16

## Threat model

**Scope:** verify the EFI boot chain (systemd-boot → UKI/kernel) using self-owned signing keys enrolled in firmware alongside Microsoft CA keys.

**Out of scope:** kernel module loading integrity. Verified against the CachyOS kernel config (`linux-cachyos/config`):

| Config | Value | Effect |
|--------|-------|--------|
| `CONFIG_MODULE_SIG_FORCE` | not set | Module signatures are not required to load modules |
| `CONFIG_LOCK_DOWN_IN_EFI_SECURE_BOOT` | absent | No auto-lockdown under secure boot |
| `CONFIG_LOCK_DOWN_KERNEL_FORCE_NONE` | `y` | Default lockdown level = none |
| `CONFIG_INTEGRITY_CA_MACHINE_KEYRING` | not set | MOK-enrolled CA certs do not enter the machine keyring |
| `CONFIG_SYSTEM_TRUSTED_KEYS` | `""` | No additional trusted keys compiled in |

`CONFIG_LOCK_DOWN_IN_EFI_SECURE_BOOT` is the option that makes a kernel auto-enter `lockdown=integrity` when it detects secure boot — it is **not present** in the CachyOS config. Combined with `LOCK_DOWN_KERNEL_FORCE_NONE=y`, the "module loading unrestricted under secure boot" claim is confirmed.

CachyOS's secure boot posture (confirmed by their docs at <https://wiki.cachyos.org/configuration/secure_boot_setup/>) is EFI-binary-verification only. Module loading is unrestricted. This is an acceptable posture — secure boot verifies the boot chain; module loading integrity is out of scope (would require a kernel rebuild with `MODULE_SIG_FORCE` + `INTEGRITY_CA_MACHINE_KEYRING`).

The CachyOS PKGBUILD's `_sign_modules()` signs modules with `certs/signing_key.x509` — an ephemeral key generated fresh during each `make` and compiled into the kernel's builtin trusted keyring. It is not shipped in the package, not published anywhere, and changes with every kernel build. There is no CachyOS-published cert to enroll. The dropped #34 was based on the false premise that one exists. See #34 for the full analysis and <https://github.com/CachyOS/linux-cachyos/issues/743> for the `INTEGRITY_CA_MACHINE_KEYRING` context.

## Key model

Three key hierarchies (PK, KEK, db), matching the [sbctl](https://man.archlinux.org/man/sbctl.8.en) model. The developer's existing keys are sbctl-generated (RSA 4096), shared with CachyOS and the Fedora sealed desktop images.

| Key | Role |
|-----|------|
| PK | Firmware Platform Key (root of trust) |
| KEK | Firmware Key Exchange Key (updates db) |
| db | Signs both the UKI (#32) and `systemd-boot` (#33); enrolled in firmware |

One key (db) signs all EFI binaries — same as `sbctl sign`. No separate VENDOR, SYSEXT, or linux-module-cert keys: VENDOR merged into db (sbctl model), SYSEXT not in current scope, linux-module-cert dropped with #34 (CachyOS module signing handled by kernel builtin keyring).

Keys live in `files/boot-keys/` (gitignored) when on disk:

```
files/boot-keys/
├── PK.key
├── PK.crt
├── KEK.key
├── KEK.crt
├── db.key
├── db.crt
└── extra-db/       # empty dir (for Microsoft certs included in db.auth)
```

### Key retrieval: Proton Pass via fnox (#311)

Keys are stored as custom hidden fields in a Proton Pass vault item (e.g. an item "Secure Boot Keys" with fields `PK.key`, `PK.crt`, `KEK.key`, etc.). A committed `fnox.toml` maps secret names to `pass://` references — it contains only references, no actual secrets.

`fnox` wraps the Proton Pass CLI (`pass-cli`) and resolves the references at retrieval time. The developer logs in once with `pass-cli login` (browser-based); after that `mise run pull-keys` retrieves all 6 key/cert files (3 key pairs) and validates them with openssl.

This is the preferred path for an existing key set. The `generate-keys` task (#31) remains as a fallback for generating fresh keys on a clean checkout without Proton Pass configured.

### Key lifecycle

```
pass-cli login (one time, browser-based)
  └─ mise run pull-keys (#311) → fnox get → files/boot-keys/ (6 files, validated)
       └─ mise run seal-uki (#32) → podman build --secret … (keys never enter the image layer)
            └─ keys exist only during the RUN step (podman --secret mounts)
```

Private keys are passed via podman `--secret` mounts and exist only during the `RUN` step — they never enter the image layer. This replaces the earlier `shred -u` approach (unreliable on COW filesystems). Certs (`.crt`) are public.

Enrollment bundles Microsoft's well-known CA certs (2011 + 2023) in the db.auth signature list (for third-party EFI binary support). OEM-specific keys from `dbDefault` are not generically preserved — see #309 for the limitation.

## Architecture decisions (resolved)

All design gates are resolved. The decisions below were verified against bootc v1.16.3 source (`crates/lib/src/ukify.rs`, `docs/src/man/bootc-container-ukify.8.md`), the bootc `contrib/packaging/seal-uki` script, the bootc `bootc install` man page, the fnox Proton Pass provider docs (<https://fnox.jdx.dev/providers/proton-pass.html>), and the systemd-boot man page.

### 0. Key retrieval: Proton Pass via fnox (#311)

**Decision:** Retrieve signing keys from Proton Pass via `fnox get` in a `mise run pull-keys` task. Not stored persistently on disk by default.

Keys are stored as custom hidden fields in a Proton Pass vault item. A committed `fnox.toml` maps secret names to `pass://vault/item/field` references (no secrets in the repo). `fnox` wraps `pass-cli` to resolve them.

`pull-keys` writes all 6 key/cert files (3 key pairs: PK, KEK, db) to `files/boot-keys/` and validates each with `openssl rsa -check` / `openssl x509 -noout`. Private keys are `chmod 600`; certs are `chmod 644`.

The `generate-keys` task (#31) remains as a fallback for fresh key generation when Proton Pass is not configured.

**Rejected alternatives:**

| Alternative | Why rejected |
|-------------|--------------|
| Store keys as GitHub Actions secrets | Works for CI but clutters secret management. One Proton Pass token replaces all key files. |
| Keys persist on disk only | Keys sit on disk between signing sessions. Proton Pass retrieval allows pulling on demand. |

### 1. UKI build + bootloader signing: expanded Containerfile (#32, #33)

**Decision:** Build and sign the UKI inside the krytis image via an expanded `Containerfile`, not as a host mise task and not as a BST element.

The existing `Containerfile` already does `FROM localhost/krytis-input:latest` → `RUN bootc container lint` → produces `localhost/krytis:latest`. This is the correct pattern — `FROM` preserves all bootc metadata (`containers.bootc=1`, `CMD ["/sbin/init"]`, `STOPSIGNAL SIGRTMIN+3`), and the UKI is added as a clean layer. No manual OCI extraction/repackaging.

Expanding it with a conditional signing step (gated by a `SEAL_SECURE_BOOT` build arg) keeps everything in one file and runs `bootc container ukify` / `sbsign` from inside the image, where bootc v1.16.3, `ukify`, and `sbsign` all live.

```dockerfile
FROM localhost/krytis-input:latest

# Existing: bootc container lint
RUN bootc container lint

# Conditional secure boot sealing — gated by build arg.
# mise build (unsigned) skips this; mise run seal-uki enables it.
ARG SEAL_SECURE_BOOT=false

RUN --mount=type=secret,id=db_key --mount=type=secret,id=db_crt \
    --mount=type=secret,id=kek_key --mount=type=secret,id=kek_crt \
    --mount=type=secret,id=pk_key --mount=type=secret,id=pk_crt \
    if [ "$SEAL_SECURE_BOOT" = "true" ]; then \
        mkdir -p /boot/EFI/Linux && \
        bootc container ukify -- \
            --secureboot-private-key /run/secrets/db_key \
            --secureboot-certificate /run/secrets/db_crt \
            --signtool sbsign \
            --output /boot/EFI/Linux/krytis.efi && \
        sbsign --key /run/secrets/db_key --cert /run/secrets/db_crt \
            --output /boot/EFI/systemd/systemd-bootx64.efi \
            /boot/EFI/systemd/systemd-bootx64.efi \
    ; fi
```

**Keys via `--secret` mounts:** keys exist only during the `RUN` step and never enter the image layer. The `mise run seal-uki` task passes `--secret` flags from `files/boot-keys/` (pulled by `mise run pull-keys`).

**`bootc container ukify`** (bootc v1.16.3) natively handles:
1. Finds the kernel in the rootfs
2. Computes the composefs digest via `compute_composefs_digest()` — `/boot` is **outside the composefs-verified tree** (the UKI is signed and verified by secure boot, not composefs)
3. Reads `kargs.d/*.toml` and resolves them into a cmdline string (`get_kargs_in_root()`)
4. Appends `composefs=<digest>` to the cmdline automatically
5. Invokes `ukify build` with `--linux`, `--initrd`, `--uname`, `--cmdline`, `--os-release` — all computed

**Why not a host mise task (Blocker 1):** `bootc container ukify` v1.16.3 lives in the krytis image, not on the host. A host mise task would depend on whatever bootc the developer has installed. Running inside the image guarantees the correct version.

**Why not manual OCI extraction (Blocker 2):** `podman export`/`import` flattens layers and drops image config — losing `containers.bootc=1`. `FROM` in a Containerfile preserves all metadata.

**Rejected alternatives:**

| Alternative | Why rejected |
|-------------|--------------|
| BST element (`core/uki.bst`) | Circular dep: UKI in the filesystem → digest depends on UKI. Manual cmdline resolution (no bootc in BST sandbox). High complexity for no benefit. |
| Host mise task (`bootc container ukify` on host) | Wrong bootc version (host may not have v1.16.3). Keys on host filesystem. |
| Manual OCI extraction/repackaging | Flattens layers, drops `containers.bootc=1` / `CMD` / `STOPSIGNAL`. Bootc image becomes non-bootable. |
| Install-time only (`bootc install` generates UKI) | Not reproducible across machines. UKI not in the image. |

**Flow:**

```
mise build           → load-image (BST) + lint (Containerfile, SEAL_SECURE_BOOT=false) → localhost/krytis:latest
mise run seal-uki    → podman build --build-arg SEAL_SECURE_BOOT=true --secret … → localhost/krytis:sealed
mise run generate-disk → bootc install to-disk (from sealed image)
```

**Runtime deps to add to the image:** `freedesktop-sdk.bst:components/systemd-ukify.bst` (provides `ukify` + EFI stub), `freedesktop-sdk.bst:components/sbsigntools.bst` (provides `sbsign`), `freedesktop-sdk.bst:components/efitools.bst` (provides `cert-to-efi-sig-list` / `sign-efi-sig-list` for #309). Verify the EFI stub (`/usr/lib/systemd/boot/efi/linuxx64.efi.stub`) is present — `systemd-ukify.bst` is a filter over `systemd-base.bst` which builds with `-Defi=true -Dbootloader=true` on x86_64.

### kargs immutability

With a UKI, the kernel cmdline is **frozen inside the signed PE**. `bootc kargs` and editing `kargs.d` post-install have **no effect** on a UKI boot. Currently krytis ships `kargs.d/20-plymouth.toml` (`quiet splash`) and `30-fido2-luks.toml` (`rd.luks.options=fido2-device=auto`) — these are baked into the UKI at seal time by `bootc container ukify`'s `get_kargs_in_root()`. Confirm this picks up krytis's `kargs.d` correctly.

If users need runtime karg changes, signed UKI addons (`.addon.efi` in `loader/addons/` or `<uki>.efi.extra.d/`) are the mechanism (travier documents this). Out of scope for this epic but noted for future.

### 2. Bootloader signing: install-time, no shim (#33)

**Decision:** Sign `systemd-boot` with `sbsign` during the `seal-uki` Containerfile step. No shim initially.

krytis's boot flow uses `bootc install --bootloader systemd`, which installs `systemd-boot` to the ESP at install time. Signing happens in the expanded `Containerfile` alongside the UKI build — `sbsign --key db.key --cert db.crt` on the `systemd-boot` binary, using the db key passed via a `--secret` mount. `bootc install` then installs the pre-signed copy.

**No shim:** The user's db key is enrolled directly via systemd-boot's native `loader/keys/` mechanism (see decision 3 below). shim is only needed for MOK fallback enrollment or firmware that only trusts Microsoft's keys. Add shim later only if those scenarios arise.

**Rejected alternative:** Ship pre-signed `shim` + `systemd-boot` in the image at `/boot/EFI/` (fdsdk approach). Rejected because it fights bootc's install-time bootloader model, adds shim chainloading / `BOOT<ARCH>.EFI` remapping complexity, and complicates the upgrade flow.

### 3. Key enrollment: systemd-boot native (#309)

**Decision:** Use systemd-boot's native key enrollment via `loader/keys/` on the ESP, automated by bootc's `/usr/lib/bootc/install/secureboot-keys` mechanism.

bootc documents this flow (`bootc install` man page, "Secure Boot Keys" section): place signed EFI signature lists (`.auth` files) at `/usr/lib/bootc/install/secureboot-keys/auto/` in the image. At `bootc install --bootloader systemd` time, bootc copies them to `ESP/loader/keys/auto/`. systemd-boot enrolls them at first boot.

**`.auth` file generation** uses efitools (`cert-to-efi-sig-list` + `sign-efi-sig-list`), available as `freedesktop-sdk.bst:components/efitools.bst`. NOT `efi-keytool` from `efivar` — that was an incorrect tool identification in an earlier draft.

**Enrollment replaces, not merges.** systemd-boot's `loader/keys/auto` enrollment **replaces** PK/KEK/db with exactly what's in the `.auth` files — it is not `sbctl enroll-keys --microsoft --firmware-builtin`, which merges the firmware's existing `dbDefault`/`KEKDefault`. Microsoft's CA certs (2011 + 2023) **can** be retained by explicitly bundling them into the `db.auth` signature list. OEM-specific keys from `dbDefault` **cannot** be generically preserved (they're per-machine). Bundling Microsoft's well-known CAs is sufficient for most users (Option ROMs, third-party bootloaders).

**`secure-boot-enroll` in `loader.conf`:** systemd-boot does **not** auto-enroll on real hardware by default. The default `secure-boot-enroll=if-safe` only auto-enrolls in recognized VMs. On real hardware, the user must manually select the key set in the boot menu, or enrollment is a silent no-op. Set `secure-boot-enroll manual` in `loader.conf` and document the firmware-setup-mode + boot-menu flow.

**No `mokutil` or `sbctl` needed** in the image — build-time signing uses `sbsign`/`ukify` directly, and enrollment is handled by systemd-boot natively. Neither `mokutil` nor `sbctl` exists in the fdsdk junction.

**QEMU testing:** Use `virt-fw-vars --secure-boot --set-pk … --add-kek … --add-db …` to bake keys directly into an OVMF vars file (reference: travier `generate-ovmf-vars` recipe). This is the test path; `loader/keys/` is the real-hardware path.

**Rejected alternatives:**

| Alternative | Why rejected |
|-------------|--------------|
| `mokutil --import` | Not in fdsdk junction (would need new element). Interactive prompt at first boot. Not bootc-integrated. |
| `sbctl enroll-keys` | Not in fdsdk junction (would need new element). Manual command from running system. Not bootc-integrated. |

### 4. CI signing strategy: prerequisite for registry publishes

**CI signing is a hard prerequisite for publishing to a registry that secure-boot users track.** If CI publishes unsigned images, a secure-boot user who runs `bootc upgrade` pulls an unsigned UKI → firmware rejects it → unbootable. This is not a "future nicety" — it's required from day one.

**Resolution:** CI signs from day one using a single `PROTON_PASS_PERSONAL_ACCESS_TOKEN` as a GitHub Actions secret. CI runs `pass-cli login --personal-access-token $TOKEN` → `mise run pull-keys` → `mise run seal-uki` → publishes the **signed** image. One token instead of 6 key files.

If CI signing is not ready, the unsigned image must **not** be published to the public registry — it stays as `localhost/krytis-input:latest` (the BST output) and `localhost/krytis:latest` (lint-only). Only the sealed image is published.

### 5. Breakage gate: fido2-luks / TPM (#312)

Adding a signed UKI changes PCR measurements (PCR 4 = boot manager, PCR 7 = secure boot policy), which can break TPM-based LUKS unlock. krytis ships `30-fido2-luks.toml`. This is a Breakage Gate per AGENTS.md — #312 must be cleared before the full boot chain is verified. `ukify --measure` and `systemd-tpm2-*` service handling are in scope. travier's `uki.sh` uses `--measure` and masks several `systemd-tpm2-*` services as a workaround.

## Status in sibling / reference projects

- **fdsdk** (`vm/minimal-secure/`): complete reference implementation — `ukify build` + `sbsign` for shim/bootloader. Good signing-mechanics reference, but **different boot flow** (standalone disk image, not bootc + composefs). Uses build-time signing and replaces firmware keys entirely — not the model here.
- **travier / fedora-atomic-desktops-sealed** (<https://github.com/travier/fedora-atomic-desktops-sealed>): **primary analog** — bootc + composefs + UKI + secure boot. Uses `Containerfile.uki` with `FROM` the base image, `--secret` mounts for keys, `bootc container ukify` + `sbsign` inside the container. See `scripts/uki.sh`, `Containerfile.uki`, `justfile`. Note: travier's `uki.sh` marks `bootc container ukify` as FIXME/disabled — that was an older bootc; v1.16.3 makes it production-ready.
- **zirconium-hawaii**: key scaffolding in place (`files/boot-keys/`, `core/linux-module-cert.bst`, `files/boot-keys/` in `.gitignore`) but signing not yet wired up. `generate-keys` Justfile recipe is the reference for #31.
- **dakota**: no secure boot. Uses `bluefin/unsigned-modules.bst` (extracts fdsdk kernel modules as-is).
- **bootc** (`contrib/packaging/seal-uki`, `contrib/packaging/finalize-uki`): bootc's own reference scripts for sealed UKI images. `seal-uki` wraps `bootc container ukify` as a one-liner.

## What needs to happen

### 1. Key retrieval (`mise run pull-keys`) — #311

Retrieve keys from Proton Pass via `fnox get` into `files/boot-keys/`. Validate with openssl. See `fnox.toml` for the reference mapping.

### 2. Key generation (`mise run generate-keys`) — #31

Fallback for fresh key generation when Proton Pass is not configured. Keys live in `files/boot-keys/` (already `.gitignore`d). Idempotent task generating 3 key pairs (PK, KEK, db), RSA 4096 to match sbctl:

```bash
openssl req -new -x509 -newkey rsa:4096 -subj "/CN=Krytis <KEY>/" \
    -keyout files/boot-keys/<KEY>.key -out files/boot-keys/<KEY>.crt \
    -days 3650 -nodes -sha256
```

Keys needed: `PK`, `KEK`, `db`.

Guard: skip generation if `.key` + `.crt` already exist (reuse developer's existing keys). Also ensure `extra-db/` subdirectory exists (for Microsoft certs included in db.auth during enrollment — see #309).

### 3. UKI assembly + bootloader signing (`mise run seal-uki`) — #32, #33

Expand the existing `Containerfile` with a conditional `SEAL_SECURE_BOOT` build arg. When enabled, `bootc container ukify` builds and signs the UKI, and `sbsign` signs `systemd-boot` — all inside the image, with keys passed via `--secret` mounts. See the Containerfile snippet in decision 1 above.

**Runtime deps to add:** `components/systemd-ukify.bst`, `components/sbsigntools.bst`, `components/efitools.bst`. Verify EFI stub (`linuxx64.efi.stub`) present.

### 4. Firmware key enrollment — #309

Generate `.auth` files from PEM keys using efitools (`cert-to-efi-sig-list` + `sign-efi-sig-list`). Bundle Microsoft CA certs in db.auth. Place at `/usr/lib/bootc/install/secureboot-keys/auto/` in the image via a BST element. Set `secure-boot-enroll manual` in `loader.conf`. bootc + systemd-boot handle the rest at install/boot time.

For QEMU testing: `virt-fw-vars` to bake keys into OVMF vars.

### 5. fido2-luks / TPM Breakage Gate — #312

Analyze PCR impact of signed UKI on TPM-bound LUKS. Evaluate `ukify --measure` and `systemd-tpm2-*` service handling. Must be cleared before full boot chain verification.

### 6. ~~CachyOS kernel module signing~~ — dropped (#34)

~~MOK enrolment of CachyOS's signing cert.~~ Closed as based on a false premise — see "Threat model" above and #34 for the full analysis.

## Suggested element / task layout

```
# BST elements (runtime deps for signing/enrollment tools)
elements/core/secure-boot-tools.bst   # systemd-ukify + sbsigntools + efitools (runtime dep)
elements/config/secureboot-keys.bst   # .auth files → /usr/lib/bootc/install/secureboot-keys/auto/
elements/config/loader-config.bst     # secure-boot-enroll manual in loader.conf

# Config (committed — references only, no secrets)
fnox.toml                              # #311 — Proton Pass secret references

# Containerfile (expanded — conditional signing)
Containerfile                          # existing lint + conditional SEAL_SECURE_BOOT step

# Mise tasks
mise/tasks/pull-keys                  # #311 — fnox get → files/boot-keys/ (validated)
mise/tasks/generate-keys              # #31 — idempotent key generation (fallback)
mise/tasks/seal-uki                   # #32 + #33 — podman build --build-arg SEAL_SECURE_BOOT=true --secret …
```

`oci/krytis/image.bst` gains `secure-boot-tools.bst`, `secureboot-keys.bst`, and `loader-config.bst` as depends. The `seal-uki` task runs `podman build` against the expanded `Containerfile`.

## CI signing strategy

**Prerequisite for registry publishes.** CI signs from day one using a single `PROTON_PASS_PERSONAL_ACCESS_TOKEN` as a GitHub Actions secret. CI runs `pass-cli login --personal-access-token $TOKEN` → `mise run pull-keys` → `mise run seal-uki` → publishes the signed image. One CI secret replaces 6 key files.

If CI signing is not ready, the unsigned image must not be published to the public registry.
