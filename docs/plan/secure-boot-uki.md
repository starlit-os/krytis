# Deferred: Secure Boot + Unified Kernel Image (UKI)

## Status in sibling projects

- **fdsdk** (`vm/minimal-secure/`): complete reference implementation — `ukify build` + `sbsign` for shim/bootloader. Best reference.
- **zirconium-hawaii**: key scaffolding in place (`files/boot-keys/`, `core/linux-module-cert.bst`, `files/boot-keys/` in `.gitignore`) but signing not yet wired up (sysext comment: "We'll add these when we do signing").
- **dakota**: no secure boot. Uses `bluefin/unsigned-modules.bst` (extracts fdsdk kernel modules as-is).

## What needs to happen

### 1. Key generation (`mise run generate-keys`)

Keys live in `files/boot-keys/` (already `.gitignore`d). Need a task modelled on zirconium's `generate-keys` Justfile recipe:

```bash
openssl req -new -x509 -newkey rsa:2048 -subj "/CN=Krytis <KEY>/" \
    -keyout files/boot-keys/<KEY>.key -out files/boot-keys/<KEY>.crt \
    -days 3650 -nodes -sha256
```

Keys needed: `PK`, `KEK`, `DB`, `VENDOR`, `SYSEXT`, `linux-module-cert`.

### 2. UKI assembly (`core/uki.bst` or extend `core/initramfs.bst`)

Use `systemd-ukify` (already available via `freedesktop-sdk.bst:components/systemd-ukify.bst`,
already in our junction overrides) to combine:

- kernel vmlinuz (`core/linux-cachyos.bst` → `/usr/lib/modules/<kver>/vmlinuz`)
- initramfs (`core/initramfs.bst`)
- kernel cmdline

Output: a single signed `.efi` file at `/boot/EFI/Linux/krytis_<version>.efi`.

Reference: `fdsdk:vm/minimal-secure/signed-boot.bst` — it extracts `.linux`, `.initrd`, `.cmdline`
sections from an existing UKI stub using `objcopy` then calls `ukify build --secureboot-private-key`.

### 3. Bootloader signing

Sign `systemd-boot` and shim with `sbsigntools` (`sbsign`):

- `systemd-boot<efi-arch>.efi` → signed with `VENDOR.key`
- `shim<efi-arch>.efi` / `BOOT<ARCH>.EFI` → signed with `DB.key`

### 4. CachyOS kernel module signing (wrinkle)

CachyOS pre-built kernel modules are already signed with **CachyOS's own key**, not ours.
With secure boot enabled, the kernel will refuse to load modules signed by an unknown key.

Options (pick one):

| Option | Approach | Notes |
|--------|----------|-------|
| **MOK enrolment** | Enrol CachyOS's signing cert into the MOK database at first boot | Easiest. User-visible enrolment prompt at first boot. |
| **Re-sign modules** | Extract all `.ko` files and re-sign with our `linux-module-cert` key | Complex. Breaks if CachyOS updates the kernel between our builds. |
| **Rebuild kernel** | Build CachyOS-patched kernel from source with our signing key | Correct but very slow. Eliminates the pre-built advantage. |

MOK enrolment is the practical choice for now. Add the CachyOS public cert to
`files/boot-keys/extra-db/` (zirconium has this directory pattern) and enrol via
`mokutil` at firstboot.

### 5. `core/linux-module-cert.bst`

Modelled on `zirconium-hawaii/elements/core/linux-module-cert.bst`:

```yaml
kind: import
sources:
- kind: local
  path: files/boot-keys/modules
config:
  target: /keys
```

Only relevant if we move to option 2 or 3 above (re-signing or source build).
Not needed for MOK enrolment path.

## Suggested element layout (when implemented)

```
core/linux-module-cert.bst      # module signing cert (if re-signing)
core/uki.bst                    # ukify build → signed .efi
oci/krytis/signed-boot.bst      # sbsign shim + systemd-boot
```

`oci/krytis/image.bst` would gain `signed-boot.bst` as a build-depend and place the
signed EFI artifacts in `/boot/EFI/`.
