# Enrolling krytis's Secure Boot Keys on Real Hardware

krytis ships its own PK/KEK/db keys (see `docs/plan/secure-boot-uki.md`) and signs
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

**Preserved:** Microsoft's 2011 and 2023 UEFI CA certs are bundled into `db.auth`
(see `docs/skills/secure-boot.md` § `.auth` generation), so third-party EFI binaries
signed by Microsoft — Option ROMs, GPU/NIC firmware, a Windows bootloader for
dual-boot — continue to verify after enrollment.

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
