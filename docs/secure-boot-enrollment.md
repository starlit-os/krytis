# Enrolling krytis's Secure Boot Keys on Real Hardware

krytis ships its own PK/KEK/db keys (see `docs/design/secure-boot-uki.md`) and signs
the UKI + `systemd-boot` against them. On real hardware — unlike the QEMU test path,
which bakes keys directly into OVMF vars via `mise run generate-ovmf-vars` — you must
enroll them through the firmware's own Secure Boot setup flow.

## Prerequisites

- A `bootc install`ed krytis system (from `localhost/krytis:sealed`, not `:latest` —
  an unsigned install has nothing to enroll against and secure boot must be **off**
  until enrollment completes, or the machine won't boot at all)
- Physical or remote (IPMI/vPro) access to the firmware setup screen

## 1. Put the firmware in Setup Mode

Reboot into UEFI firmware setup (varies by vendor — commonly `Del`, `F2`, or `F10` at
POST). Find the Secure Boot section (often under "Security" or "Boot"):

1. **Clear existing keys / enter Setup Mode.** Look for "Clear Secure Boot keys",
   "Reset to Setup Mode", or similar. This removes the firmware's factory PK, which
   is what allows new keys to be enrolled at all — Secure Boot cannot be enrolled
   into while the factory PK is still present and locked.
2. Some firmware requires Secure Boot to be **disabled** before you can clear keys,
   then leave Secure Boot in "Setup Mode" (not "enabled", not "disabled" — a distinct
   third state) before rebooting.
3. Save and exit. The machine reboots in Setup Mode — Secure Boot is architecturally
   present but not enforcing (any code can execute) until keys are enrolled.

## 2. Boot krytis and select the key set in the systemd-boot menu

With `secure-boot-enroll manual` set (krytis does this automatically on first boot —
see `docs/skills/secure-boot.md` § First-boot loader.conf edits), systemd-boot shows
an **"Enroll Secure Boot keys"** entry in its boot menu on every boot while the
firmware remains in Setup Mode:

1. At the systemd-boot menu, select **"Enroll Secure Boot keys"** (not the default
   krytis entry).
2. Confirm the enrollment when prompted — systemd-boot writes krytis's PK, KEK, and
   db (from `ESP/loader/keys/auto/*.auth`, placed there by `bootc install` from the
   image's `/usr/lib/bootc/install/secureboot-keys/auto/` — see
   `docs/skills/secure-boot.md` § `.auth` files land at `secureboot-keys/<keyset>/*.auth`)
   into the firmware's PK/KEK/db variables.
3. Enrolling the PK exits Setup Mode and enters **User Mode** — Secure Boot begins
   enforcing immediately, including for the current boot.
4. Reboot. Confirm in the firmware setup screen (or `bootctl status` from within
   krytis) that Secure Boot now shows **enabled (user)**.

## 3. Verify

```bash
bootctl status | grep "Secure Boot"
# Expected: Secure Boot: enabled (user)
```

## What this enrollment does and doesn't preserve

**Partially preserved — and the gaps matter.** Microsoft publishes **five**
certificates for `db` ([microsoft/secureboot_objects](https://github.com/microsoft/secureboot_objects)
`PreSignedObjects/DB/Certificates/`). krytis bundles two of them:

| Microsoft's `db` certificate | in krytis's `db.auth`? | signs |
|---|---|---|
| Microsoft Corporation UEFI CA 2011 | **yes** | shims, most third-party option ROMs |
| Windows UEFI CA 2023 | **yes** | Windows binaries signed under the 2023 chain |
| Microsoft Windows Production PCA 2011 | **no** | `bootmgfw.efi` on essentially every current Windows 10/11 install |
| Microsoft UEFI CA 2023 | **no** | newer third-party binaries |
| Microsoft Option ROM UEFI CA 2023 | **no** | option ROMs signed under the 2023 chain |

So a distro `shimx64.efi` keeps working — its chain is
`Microsoft Windows UEFI Driver Publisher` → `Microsoft Corporation UEFI CA 2011`,
verified directly against the cert we ship. **An existing Windows install most likely
does not:** its boot manager is signed under Windows Production PCA 2011, which we do
not enrol, so after enrollment the firmware refuses it. Do not enrol krytis's keys on
a machine whose Windows partition you need to boot until that is resolved
([#464](https://github.com/starlit-os/krytis/issues/464)).

Check any specific binary before trusting it — read the chain, do not ask a verifier:

```bash
sbverify --list bootx64.efi | grep -A1 subject   # the issuer CN is the answer
```

`sbverify --cert <ca> <binary>` is **not** a coverage test: it reports
`Signature verification OK` for an unrelated certificate, including krytis's own db
cert against a Microsoft-signed shim.

**NOT preserved:** enrollment via `loader/keys/auto/*.auth` **replaces** the
firmware's PK/KEK/db outright — it does not merge with whatever `dbDefault`/
`KEKDefault` your specific OEM shipped (vendor-specific option ROM signing keys,
etc.). If you rely on OEM-signed firmware components beyond what's covered by
Microsoft's CAs, they will stop verifying after this enrollment. There is no generic
per-machine fix for this — OEM defaults vary per vendor and aren't knowable at image
build time. If you hit this, you'll see a specific option ROM or add-in card refuse
to initialize under Secure Boot; the fix is case-by-case (contact the vendor for a
Secure Boot-signed firmware update, or accept running without Secure Boot for that
component).

## Recovering from a bad enrollment

If the machine fails to boot after enrollment (extremely rare — this would mean the
.auth files were malformed, which `mise run boot-test --secure` should have already
caught in CI before this image was published): re-enter firmware setup and use the
vendor's "Restore Secure Boot to factory defaults" or "Clear Secure Boot keys" option
again. This returns the firmware to Setup Mode, from which you can either re-enroll
or leave Secure Boot disabled.
