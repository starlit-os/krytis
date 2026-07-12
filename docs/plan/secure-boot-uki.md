# Secure Boot + Unified Kernel Image (UKI)

Tracking epic: #16

## Threat model

**Scope:** verify the EFI boot chain (shim → systemd-boot → UKI/kernel) using self-owned signing keys enrolled in firmware alongside Microsoft/OEM keys.

**Out of scope:** kernel module loading integrity. Verified against the CachyOS kernel config (`linux-cachyos/config`):

| Config | Value | Effect |
|--------|-------|--------|
| `CONFIG_MODULE_SIG_FORCE` | not set | Module signatures are not required to load modules |
| `CONFIG_SECURITY_LOCKDOWN_LSM_EARLY` | not set | Secure boot does not auto-trigger kernel lockdown |
| `CONFIG_INTEGRITY_CA_MACHINE_KEYRING` | not set | MOK-enrolled CA certs do not enter the machine keyring |
| `CONFIG_SYSTEM_TRUSTED_KEYS` | `""` | No additional trusted keys compiled in |

CachyOS's secure boot posture (confirmed by their docs at <https://wiki.cachyos.org/configuration/secure_boot_setup/>) is EFI-binary-verification only. Module loading is unrestricted. This is an acceptable posture — secure boot verifies the boot chain; module loading integrity is out of scope (would require a kernel rebuild with `MODULE_SIG_FORCE` + `INTEGRITY_CA_MACHINE_KEYRING`).

The CachyOS PKGBUILD's `_sign_modules()` signs modules with `certs/signing_key.x509` — an ephemeral key generated fresh during each `make` and compiled into the kernel's builtin trusted keyring. It is not shipped in the package, not published anywhere, and changes with every kernel build. There is no CachyOS-published cert to enroll. The dropped #34 was based on the false premise that one exists. See #34 for the full analysis and <https://github.com/CachyOS/linux-cachyos/issues/743> for the `INTEGRITY_CA_MACHINE_KEYRING` context.

## Key strategy

The developer's existing signing keys (shared with CachyOS and the Fedora sealed desktop images) are reused. Keys live in `files/boot-keys/` (gitignored). The `generate-keys` task (#31) is idempotent insurance — a no-op when keys already exist, generates fresh keys only as a fallback.

Enrollment keeps Microsoft/OEM keys (`sbctl enroll-keys --microsoft --firmware-builtin` pattern) — adds krytis's keys alongside, does not replace. Third-party EFI binaries continue to work.

## Status in sibling / reference projects

- **fdsdk** (`vm/minimal-secure/`): complete reference implementation — `ukify build` + `sbsign` for shim/bootloader. Good signing-mechanics reference, but **different boot flow** (standalone disk image, not bootc + composefs).
- **travier / fedora-atomic-desktops-sealed** (<https://github.com/travier/fedora-atomic-desktops-sealed>): **primary analog** — bootc + composefs + UKI + secure boot. Multi-stage container build: rootfs → rechunk → compute composefs digest → build UKI → copy UKI into final image. See `scripts/uki.sh`, `Containerfile.uki`, `justfile`.
- **zirconium-hawaii**: key scaffolding in place (`files/boot-keys/`, `core/linux-module-cert.bst`, `files/boot-keys/` in `.gitignore`) but signing not yet wired up. `generate-keys` Justfile recipe is the reference for #31.
- **dakota**: no secure boot. Uses `bluefin/unsigned-modules.bst` (extracts fdsdk kernel modules as-is).

## What needs to happen

### 1. Key generation (`mise run generate-keys`) — #31

Keys live in `files/boot-keys/` (already `.gitignore`d). Idempotent task modelled on zirconium's `generate-keys` Justfile recipe:

```bash
openssl req -new -x509 -newkey rsa:2048 -subj "/CN=Krytis <KEY>/" \
    -keyout files/boot-keys/<KEY>.key -out files/boot-keys/<KEY>.crt \
    -days 3650 -nodes -sha256
```

Keys needed: `PK`, `KEK`, `DB`, `VENDOR`, `SYSEXT`, `linux-module-cert`.

Guard: skip generation if `.key` + `.crt` already exist (reuse developer's existing keys). Also ensure `extra-db/` and `modules/` subdirectories exist; copy `linux-module-cert.crt` into `modules/`.

### 2. UKI assembly — #32

Use `systemd-ukify` (`freedesktop-sdk.bst:components/systemd-ukify.bst`) to combine:

- kernel vmlinuz (`core/linux-cachyos.bst` → `/usr/lib/modules/<kver>/vmlinuz`)
- initramfs (`core/initramfs.bst`)
- kernel cmdline (resolved from `files/bootc-config/kargs.d/*.toml` at build time)
- composefs digest of the final rootfs

Output: a single signed `.efi` file at `/boot/EFI/Linux/krytis_<version>.efi`.

**Composefs digest chicken-and-egg.** The UKI cmdline must contain the composefs digest of the final rootfs, but the digest depends on image content that includes the UKI. travier solves this with multi-stage container builds (rootfs → rechunk → compute digest → build UKI → copy UKI into final image). In BST, this needs a decision:

- (a) UKI built in BST, digest computed over `oci/krytis/filesystem.bst` (UKI is not part of that filesystem — lands in a separate `/boot` layer)
- (b) UKI built **post-BST** at container assembly time (travier's `Containerfile.uki` model) — `image.bst` or a downstream step runs `bootc container compute-composefs-digest` + `ukify build`

**Cmdline resolution.** `kargs.d/*.toml` is currently applied by bootc at deploy time. With a UKI, the cmdline is baked in at build time. Must evaluate whether `bootc container ukify` does this natively (travier marks it FIXME/disabled and resolves manually) and whether it's usable in the BST sandbox.

**Boot flow interaction.** The current flow uses `bootc install to-disk --bootloader systemd`, which installs systemd-boot to the ESP at install time. The OCI image has no `/boot` content (`oci/krytis/stack.bst` does `rm -rfv /boot; mkdir /boot`). A UKI at `/boot/EFI/Linux/` in the image changes this.

Reference: `fdsdk:vm/minimal-secure/signed-boot.bst` for the `ukify build --secureboot-private-key` signing syntax. Primary analog: <https://github.com/travier/fedora-atomic-desktops-sealed> `scripts/uki.sh`.

**Design gate:** the architecture decision (BST vs post-BST, UKI-in-image vs install-time) requires human sign-off before implementation.

### 3. Bootloader signing — #33

Sign `systemd-boot` and shim with `sbsigntools` (`sbsign`):

- `systemd-boot<efi-arch>.efi` → signed with `VENDOR.key`
- `shim<efi-arch>.efi` / `BOOT<ARCH>.EFI` → signed with `DB.key`

**Build-time vs install-time signing.** Krytis does not currently ship `systemd-boot` or `shim` in the OCI image. `bootc install to-disk --bootloader systemd` installs systemd-boot at install time from the host. Two options:

| Approach | Description | Tradeoff |
|----------|-------------|----------|
| **Build-time** (fdsdk) | Ship signed `shim` + `systemd-boot` in the image at `/boot/EFI/`; `bootc install` uses the pre-signed copies. Requires adding `shim.bst` and systemd-boot to the dep tree. | Self-contained image; changes the boot flow |
| **Install-time** | Sign during `bootc install` / `generate-disk`. Requires keys at install time. | Preserves current boot flow; keys on install machine |

All required tools are in the fdsdk junction: `shim.bst`, `sbsigntools.bst`, `efivar.bst`, `sign-file.bst`. Neither `systemd-boot` nor `shim` is currently in the image dep tree.

**Design gate:** build-time-vs-install-time decision requires human sign-off.

### 4. Firmware key enrollment — #309

Signing artifacts are useless if firmware does not trust the keys. Enrollment adds krytis's keys alongside Microsoft/OEM keys (does not replace).

- **Testing (QEMU):** `boot-vm`/`boot-test` needs OVMF secure boot variables with enrolled keys — `virt-fw-vars --secure-boot --set-pk … --add-kek … --add-db …` (travier `generate-ovmf-vars` recipe).
- **Real hardware:** documentation + optional tooling (`sbctl` or `mokutil` — neither is in the fdsdk junction; would need a new element). Build-time signing uses `sbsign`/`ukify` directly and does not need either tool.

### 5. ~~CachyOS kernel module signing~~ — dropped (#34)

~~MOK enrolment of CachyOS's signing cert.~~ Closed as based on a false premise — see "Threat model" above and #34 for the full analysis.

## Suggested element layout (when implemented)

```
core/uki.bst                    # ukify build → signed .efi (if BST build — #32 option a)
oci/krytis/signed-boot.bst      # sbsign shim + systemd-boot (if build-time — #33)
```

`oci/krytis/image.bst` would gain `signed-boot.bst` as a build-depend and place the signed EFI artifacts in `/boot/EFI/`.

If #32 option (b) (post-BST UKI) or #33 install-time signing is chosen, the layout differs — the signing steps move into `mise/tasks/generate-disk` or a post-BST container assembly step.

## CI key strategy (open — design gate)

Keys generated locally by a developer can't be used in CI. The signing steps (#32, #33) require keys at build time. Options:

- **Ephemeral CI keys:** generated per build — fine for testing, not for production images users trust
- **CI secrets:** signing keys as CI secrets (travier uses `--secret` mounts in podman builds)
- **Local-only signing:** CI builds unsigned images; signed images built locally only

This is a **supply chain / Security Gate** decision that needs human sign-off.
