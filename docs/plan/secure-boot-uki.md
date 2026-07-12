# Secure Boot + Unified Kernel Image (UKI)

Tracking epic: #16

## Threat model

**Scope:** verify the EFI boot chain (systemd-boot → UKI/kernel) using self-owned signing keys enrolled in firmware alongside Microsoft/OEM keys.

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

The developer's existing signing keys (shared with CachyOS and the Fedora sealed desktop images) are reused. Keys live in `files/boot-keys/` (gitignored) when on disk.

### Key retrieval: Proton Pass via fnox (#311)

Keys are stored as custom hidden fields in a Proton Pass vault item (e.g. an item "Secure Boot Keys" with fields `PK.key`, `PK.crt`, `KEK.key`, etc.). A committed `fnox.toml` maps secret names to `pass://` references — it contains only references, no actual secrets.

`fnox` wraps the Proton Pass CLI (`pass-cli`) and resolves the references at retrieval time. The developer logs in once with `pass-cli login` (browser-based); after that `mise run pull-keys` retrieves all 12 key/cert files and validates them with openssl.

This is the preferred path for an existing key set. The `generate-keys` task (#31) remains as a fallback for generating fresh keys on a clean checkout without Proton Pass configured.

### Key lifecycle

```
pass-cli login (one time, browser-based)
  └─ mise run pull-keys (#311) → fnox get → files/boot-keys/ (validated)
       └─ mise run seal-uki (#32) → signs UKI + systemd-boot
            └─ shred -u files/boot-keys/*.key (optional — minimize key exposure)
```

Private keys (`.key`) can be shredded after signing to minimize time on disk. Certs (`.crt`) are public — no need to shred.

Enrollment keeps Microsoft/OEM keys (included in the db.auth signature list) — adds krytis's keys alongside, does not replace. Third-party EFI binaries continue to work.

## Architecture decisions (resolved)

All design gates are resolved. The decisions below were verified against bootc v1.16.3 source (`crates/lib/src/ukify.rs`, `docs/src/man/bootc-container-ukify.8.md`), the bootc `contrib/packaging/seal-uki` script, the bootc `bootc install` man page, and the fnox Proton Pass provider docs (<https://fnox.jdx.dev/providers/proton-pass.html>).

### 0. Key retrieval: Proton Pass via fnox (#311)

**Decision:** Retrieve signing keys from Proton Pass via `fnox get` in a `mise run pull-keys` task. Not stored persistently on disk by default.

Keys are stored as custom hidden fields in a Proton Pass vault item. A committed `fnox.toml` maps secret names to `pass://vault/item/field` references (no secrets in the repo). `fnox` wraps `pass-cli` to resolve them.

`pull-keys` writes all 12 key/cert files to `files/boot-keys/` and validates each with `openssl rsa -check` / `openssl x509 -noout`. Private keys are `chmod 600`; certs are `chmod 644`.

The `generate-keys` task (#31) remains as a fallback for fresh key generation when Proton Pass is not configured.

**Rejected alternatives:**

| Alternative | Why rejected |
|-------------|--------------|
| Store keys as 12 GitHub Actions secrets | Works for CI but clutters secret management. One Proton Pass token replaces 12 secrets. |
| Keys persist on disk only | Keys sit on disk between signing sessions. Proton Pass retrieval allows shredding after signing. |

### 1. UKI build: post-BST mise task (#32)

**Decision:** Build the UKI **post-BST** via `mise run seal-uki`, wrapping `bootc container ukify`. Not a BST element.

`bootc container ukify` (bootc v1.16.3, pinned in `core/bootc.bst`) natively handles everything a BST element would have had to reimplement:

1. Finds the kernel in the rootfs
2. Computes the composefs digest via `compute_composefs_digest()` — no circular dependency, because the UKI is added as a separate layer after the rootfs is finalized
3. Reads `kargs.d/*.toml` and resolves them into a cmdline string (`get_kargs_in_root()`)
4. Appends `composefs=<digest>` to the cmdline automatically
5. Invokes `ukify build` with `--linux`, `--initrd`, `--uname`, `--cmdline`, `--os-release` — all computed

This is the same flow as bootc's own `contrib/packaging/seal-uki` script. A BST-in-image approach was rejected because it would require reimplementing this logic in the BST sandbox (where bootc is not available) and would create a circular dependency (UKI can't be in the filesystem it computes the composefs digest over).

**Rejected alternatives:**

| Alternative | Why rejected |
|-------------|--------------|
| BST element (`core/uki.bst`) | Circular dep: UKI in the filesystem → digest depends on UKI. Manual cmdline resolution (no bootc in BST sandbox). High complexity for no benefit. |
| Install-time only (`bootc install` generates UKI) | Not reproducible across machines. UKI not in the image. |

**Flow:**

```
mise build           → unsigned OCI image (filesystem.bst → image.bst)
mise run seal-uki    → bootc container ukify --rootfs <layer> -- --secureboot-private-key … --signtool sbsign
mise run generate-disk → bootc install to-disk (from sealed image)
```

**Runtime deps to add to the image:** `freedesktop-sdk.bst:components/systemd-ukify.bst` (provides `ukify`), `freedesktop-sdk.bst:components/sbsigntools.bst` (provides `sbsign`). Neither is currently in the dep tree.

### 2. Bootloader signing: install-time, no shim (#33)

**Decision:** Sign `systemd-boot` with `sbsign` during the `seal-uki` task. No shim initially.

krytis's boot flow uses `bootc install --bootloader systemd`, which installs `systemd-boot` to the ESP at install time. Signing happens in the `seal-uki` task alongside the UKI build — `sbsign --key DB.key --cert DB.crt` on the `systemd-boot` binary. `bootc install` then installs the pre-signed copy.

**No shim:** The user's db key is enrolled directly via systemd-boot's native `loader/keys/` mechanism (see decision 3 below). shim is only needed for MOK fallback enrollment or firmware that only trusts Microsoft's keys. Add shim later only if those scenarios arise.

**Rejected alternative:** Ship pre-signed `shim` + `systemd-boot` in the image at `/boot/EFI/` (fdsdk approach). Rejected because it fights bootc's install-time bootloader model, adds shim chainloading / `BOOT<ARCH>.EFI` remapping complexity, and complicates the upgrade flow.

### 3. Key enrollment: systemd-boot native (#309)

**Decision:** Use systemd-boot's native key enrollment via `loader/keys/` on the ESP, automated by bootc's `/usr/lib/bootc/install/secureboot-keys` mechanism.

bootc documents this flow (`bootc install` man page, "Secure Boot Keys" section): place signed EFI signature lists (`.auth` files) at `/usr/lib/bootc/install/secureboot-keys/auto/` in the image. At `bootc install --bootloader systemd` time, bootc copies them to `ESP/loader/keys/auto/`. systemd-boot enrolls them at first boot if the firmware is in setup mode.

The `.auth` files are signed EFI signature lists (not just DER certs). Generation from PEM keys requires `efi-keytool` (from `efivar`, available as `freedesktop-sdk.bst:components/efivar.bst`) or manual ASN.1 construction. The db.auth must include Microsoft's well-known public keys to retain third-party EFI binary support.

**No `mokutil` or `sbctl` needed** in the image — build-time signing uses `sbsign`/`ukify` directly, and enrollment is handled by systemd-boot natively. Neither `mokutil` nor `sbctl` exists in the fdsdk junction.

**QEMU testing:** Use `virt-fw-vars --secure-boot --set-pk … --add-kek … --add-db …` to bake keys directly into an OVMF vars file (reference: travier `generate-ovmf-vars` recipe). This is the test path; `loader/keys/` is the real-hardware path.

**Rejected alternatives:**

| Alternative | Why rejected |
|-------------|--------------|
| `mokutil --import` | Not in fdsdk junction (would need new element). Interactive prompt at first boot. Not bootc-integrated. |
| `sbctl enroll-keys` | Not in fdsdk junction (would need new element). Manual command from running system. Not bootc-integrated. |

### 4. CI key strategy: local-only signing (deferred upgrade to single Proton Pass token)

**Decision (initial):** CI builds the unsigned OCI image (`mise build`). The signed image is produced locally by the developer running `mise run seal-uki`. Keys never touch CI infrastructure.

**Future upgrade path: single Proton Pass token.** Store one `PROTON_PASS_PERSONAL_ACCESS_TOKEN` as a GitHub Actions secret. CI runs `pass-cli login --personal-access-token $TOKEN` → `fnox get` (via `mise run pull-keys`) pulls all 12 key/cert files → signing proceeds. One token instead of 12 key files — cleaner than storing each key as a separate CI secret.

## Status in sibling / reference projects

- **fdsdk** (`vm/minimal-secure/`): complete reference implementation — `ukify build` + `sbsign` for shim/bootloader. Good signing-mechanics reference, but **different boot flow** (standalone disk image, not bootc + composefs). Uses build-time signing and replaces firmware keys entirely — not the model here.
- **travier / fedora-atomic-desktops-sealed** (<https://github.com/travier/fedora-atomic-desktops-sealed>): **primary analog** — bootc + composefs + UKI + secure boot. Multi-stage container build: rootfs → rechunk → compute composefs digest → build UKI → copy UKI into final image. See `scripts/uki.sh`, `Containerfile.uki`, `justfile`. Note: travier's `uki.sh` marks `bootc container ukify` as FIXME/disabled — that was an older bootc; v1.16.3 makes it production-ready.
- **zirconium-hawaii**: key scaffolding in place (`files/boot-keys/`, `core/linux-module-cert.bst`, `files/boot-keys/` in `.gitignore`) but signing not yet wired up. `generate-keys` Justfile recipe is the reference for #31.
- **dakota**: no secure boot. Uses `bluefin/unsigned-modules.bst` (extracts fdsdk kernel modules as-is).
- **bootc** (`contrib/packaging/seal-uki`, `contrib/packaging/finalize-uki`): bootc's own reference scripts for sealed UKI images. `seal-uki` wraps `bootc container ukify` as a one-liner.

## What needs to happen

### 1. Key retrieval (`mise run pull-keys`) — #311

Retrieve keys from Proton Pass via `fnox get` into `files/boot-keys/`. Validate with openssl. See `fnox.toml` for the reference mapping.

### 2. Key generation (`mise run generate-keys`) — #31

Fallback for fresh key generation when Proton Pass is not configured. Keys live in `files/boot-keys/` (already `.gitignore`d). Idempotent task modelled on zirconium's `generate-keys` Justfile recipe:

```bash
openssl req -new -x509 -newkey rsa:2048 -subj "/CN=Krytis <KEY>/" \
    -keyout files/boot-keys/<KEY>.key -out files/boot-keys/<KEY>.crt \
    -days 3650 -nodes -sha256
```

Keys needed: `PK`, `KEK`, `DB`, `VENDOR`, `SYSEXT`, `linux-module-cert`.

Guard: skip generation if `.key` + `.crt` already exist (reuse developer's existing keys). Also ensure `extra-db/` and `modules/` subdirectories exist; copy `linux-module-cert.crt` into `modules/`.

### 3. UKI assembly + bootloader signing (`mise run seal-uki`) — #32, #33

Post-BST mise task wrapping `bootc container ukify`:

```bash
bootc container ukify --rootfs <extracted-layer> \
    -- --secureboot-private-key files/boot-keys/VENDOR.key \
       --secureboot-certificate files/boot-keys/VENDOR.crt \
       --signtool sbsign \
       --output <uki-path>
```

Then sign `systemd-boot`:

```bash
sbsign --key files/boot-keys/DB.key --cert files/boot-keys/DB.crt \
    --output <sealed-layer>/boot/EFI/systemd/systemd-bootx64.efi \
    <source-systemd-bootx64.efi>
```

**Runtime deps to add:** `components/systemd-ukify.bst`, `components/sbsigntools.bst`.

### 4. Firmware key enrollment — #309

Generate `.auth` files from PEM keys (PK, KEK, db with Microsoft keys included), place at `/usr/lib/bootc/install/secureboot-keys/auto/` in the image via a BST element. bootc + systemd-boot handle the rest at install/boot time.

For QEMU testing: `virt-fw-vars` to bake keys into OVMF vars.

### 5. ~~CachyOS kernel module signing~~ — dropped (#34)

~~MOK enrolment of CachyOS's signing cert.~~ Closed as based on a false premise — see "Threat model" above and #34 for the full analysis.

## Suggested element / task layout

```
# BST elements (runtime deps for signing tools)
elements/core/secure-boot-tools.bst   # systemd-ukify + sbsigntools + efivar (runtime dep)
elements/config/secureboot-keys.bst   # .auth files → /usr/lib/bootc/install/secureboot-keys/auto/

# Config (committed — references only, no secrets)
fnox.toml                              # #311 — Proton Pass secret references

# Mise tasks
mise/tasks/pull-keys                  # #311 — fnox get → files/boot-keys/ (validated)
mise/tasks/generate-keys              # #31 — idempotent key generation (fallback)
mise/tasks/seal-uki                   # #32 + #33 — bootc container ukify + sbsign systemd-boot
```

`oci/krytis/image.bst` gains `secure-boot-tools.bst` and `secureboot-keys.bst` as depends. The `seal-uki` task runs post-BST against the built OCI image.

## CI key strategy

**Initial: local-only signing.** CI builds unsigned (`mise build`). Developer runs `mise run pull-keys && mise run seal-uki` locally with keys pulled from Proton Pass.

**Future: single Proton Pass token.** Store `PROTON_PASS_PERSONAL_ACCESS_TOKEN` as a GitHub Actions secret. CI runs `pass-cli login --personal-access-token $TOKEN` then `mise run pull-keys` to retrieve all 12 key/cert files, then `mise run seal-uki` to sign. One CI secret replaces 12.
