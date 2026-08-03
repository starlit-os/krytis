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

---

# T4: validating a sealed release on hardware

The per-release checklist. Everything above describes the *mechanism*; this is the
ordered procedure for confirming it on a physical machine, which is the only place
several of these can be observed at all. `docs/design/secure-boot-testing.md` § T4
tracks *why* each item exists and what automation cannot reach.

Ordered so that anything which can strand the machine comes after the cheap
observations, and so a single boot yields as many answers as possible.

## 0. Before you leave the desk

```bash
# The medium must embed the PUBLISHED image, not a local build (§ release sequence)
mise run build-iso --sealed --payload-image ghcr.io/starlit-os/krytis:sealed \
                   --compression release
sha256sum output/krytis-live-sealed.iso        # record this
podman inspect ghcr.io/starlit-os/krytis:sealed --format '{{.Created}}'
```

Bring: the USB, a **second** USB carrying a Microsoft-signed EFI binary (step 5), the
FIDO2 key if you are testing step 7, and the vendor's key-clearing menu path.

Decide now whether this run includes **LUKS** — step 7 needs a LUKS install, and that
is chosen during step 2, not afterwards.

**Read the OEM caveat above before choosing the machine.** Enrollment *replaces*
`db`/`KEK`/`PK`; it does not merge with your vendor's defaults. On a laptop with
OEM-signed option ROMs you may lose a device until you restore factory keys. Pick a
machine where that is acceptable.

### Writing the medium

The ISO is hybrid MBR+GPT (`55 AA` at offset 510, `EFI PART` at 512), so it goes to
the device raw. Identify the stick by **transport**, not by letter — `sda` is a USB
stick on one machine and a system disk on the next:

```bash
lsblk -o NAME,SIZE,TYPE,TRAN,RM,MODEL     # want TRAN=usb, RM=1; nvme* are internal
sudo umount /dev/sdX*  2>/dev/null        # unmount partitions, not the device
sudo dd if=output/krytis-live-sealed.iso of=/dev/sdX bs=4M oflag=direct status=progress conv=fsync
sync
```

`of=/dev/sdX`, never `sdX1`. Afterwards the stick should show three partitions
(~50K, ~87M, and the payload) — that layout alone is decent evidence the write landed.

Verify byte-exactly, and let it report *where* it differs:

```bash
sudo cmp -n "$(stat -c%s output/krytis-live-sealed.iso)" \
     /dev/sdX output/krytis-live-sealed.iso && echo IDENTICAL
```

Two traps, both of which have produced a false "does not match":

- **Do not hand-compute `bs`/`count`.** The ISO is not a whole number of MiB, so
  `count=` arithmetic reads the wrong length and the hash cannot match. Take the size
  from `stat -c%s`, as above.
- **Do not use `iflag=direct` on the read-back, and never `2>/dev/null` it.** O_DIRECT
  on a raw USB device frequently fails outright; with stderr discarded the pipeline
  emits zero bytes and `sha256sum` cheerfully returns
  `e3b0c442…b855` — the hash of the empty string. That value means "read nothing",
  not "wrong data".

## 1. Record the pre-enrollment state

Boot anything with an EFI shell or a live Linux and capture what the firmware shipped
with — this is the *only* opportunity, and step 4 is meaningless without it:

```bash
for v in PK KEK db dbx dbDefault KEKDefault dbxDefault; do
  printf '%-12s %s\n' "$v" "$(stat -c%s /sys/firmware/efi/efivars/${v}-* 2>/dev/null || echo absent)"
done
bootctl status | grep -i 'secure boot'
```

Expect `PK absent` (or factory-populated) and the `*Default` variables sized. Save the
output.

## 2. Install from the ISO

Secure Boot **off** or in Setup Mode — the live ISO is unsigned by design (#371), so an
enforcing firmware will refuse to boot the installer itself.

Choose LUKS here if step 7 is in scope. Expected: the installer completes and the
system is installed from the offline payload with no network.

*Failure signature:* `The UKI has the wrong composefs= parameter` means the embedded
payload was mutated — the ISO is bad, not the machine. Stop and rebuild.

## 3. The enrollment prompt — the item no VM can produce

Put the firmware in **Setup Mode** (§ 1 above) and boot the installed system.

In a VM, systemd-boot treats the platform as "safe" and `if-safe` auto-enrols without
asking, so this prompt path has never been exercised. Here, `secure-boot-enroll manual`
means it *must* ask.

Record verbatim:

- [ ] Does the systemd-boot menu show an **"Enroll Secure Boot keys"** entry?
- [ ] Does selecting it *ask* for confirmation, or enrol immediately?
- [ ] Does the machine reboot itself afterwards, or continue booting?
- [ ] Exact wording of the entry and any prompt.

*Failure signature:* no entry at all → the firmware did not treat `loader/keys/auto`
as enrollable, or `loader.conf` was not written. Check `/boot/loader/loader.conf` on
the ESP for `secure-boot-enroll manual`.

## 4. Post-enrollment state — replaced, not merged

```bash
bootctl status | grep -i 'secure boot'      # expect: Secure Boot: enabled (user)
for v in PK KEK db dbx; do
  printf '%-5s %s\n' "$v" "$(stat -c%s /sys/firmware/efi/efivars/${v}-* 2>/dev/null || echo absent)"
done
```

Compare with step 1. Expected, in the same order as the sizes `virt-fw-vars` reports
in the VM tests: `PK` 1254, `KEK` 1263, `db` 4353, `dbx` 21292 — krytis's own, *not*
the OEM's, and `dbx` **present** (that is #446 landing on real firmware; a missing
dbx means every revoked Microsoft-signed binary still verifies).

**Add 4 to each when reading `/sys/firmware/efi/efivars/`** — efivarfs prefixes every
variable with a 32-bit attributes field, so `db` reads as 4357 there, not 4353. A
uniform 4-byte excess is the prefix, not a corrupt list.

- [ ] `db` size matches krytis's, so OEM defaults were replaced not merged
- [ ] Every device still initialises — no missing NIC, GPU, or add-in card

## 5. A Microsoft-signed binary still runs

The *only* real test of bundling the Microsoft CAs into `db.auth`; no offline
MS-signed binary is available to the VM path.

**Use a distro `shimx64.efi`, not a Windows bootloader.** krytis enrols two of
Microsoft's five `db` certificates (see the coverage table above, and
[#464](https://github.com/starlit-os/krytis/issues/464)). A shim chains
`Microsoft Windows UEFI Driver Publisher` → `Microsoft Corporation UEFI CA 2011`,
which we ship. A Windows boot manager chains to Windows Production PCA 2011, which we
do **not** — so a Windows entry being refused here is the *documented* state of our
`db`, not a failure of this step. Confirm which you have before booting it:

```bash
sbverify --list bootx64.efi | grep -A1 subject     # the issuer CN is the answer
```

### Preparing that USB — formatting the first partition is not enough

If the stick previously had a hybrid ISO written to it, `mkfs.vfat` on partition 1
leaves the *original ESP* in place, and the firmware boots that, not your new
partition. A stick in exactly that state looked prepared and was not:

```
sda1  vfat  LABEL=MSTEST   PART_ENTRY_NAME=ISO9660   type ebd0a0a2…  <- basic data
sda2  vfat  LABEL=EFI      PART_ENTRY_NAME=Appended2 type c12a7328…  <- the real ESP
sda3        PART_ENTRY_NAME=Gap1                     type ebd0a0a2…
```

The freshly-formatted `sda1` is a **basic data** partition; `sda2` carries the ESP type
GUID and a whole `shim`+`grub` stack from the old image. Two ways that ruins step 5:
the binary actually executed is one you never verified, and `grubx64.efi` sitting
beside the shim means it proceeds into GRUB instead of producing the "Not Found" that
proves the signature was accepted.

Check with udev, which needs no privileges:

```bash
for p in /dev/sdX?; do
  udevadm info --query=property --name="$p" |
    grep -E 'ID_PART_ENTRY_(TYPE|NAME)|ID_FS_(TYPE|LABEL)'
done
```

Put the shim on the partition whose type is `c12a7328-f81f-11d2-ba4b-00a0c93ec93b`, as
the **only** file in `EFI/BOOT/`, and move anything already there aside rather than
deleting it:

```bash
mkdir -p /run/media/$USER/EFI/EFI/BOOT.orig
mv /run/media/$USER/EFI/EFI/BOOT/* /run/media/$USER/EFI/EFI/BOOT.orig/
cp shimx64.efi /run/media/$USER/EFI/EFI/BOOT/BOOTX64.EFI
sync
```

Or wipe the stick and create a single `ef00` partition, which removes the question
permanently.

Boot the second USB from the firmware boot menu, under enforcement.

- [ ] The shim loads
- [ ] If you also tried a Windows entry, record which CA signed it and the result

**Expected success looks like a shim error.** A standalone shim verifies, starts, then
fails to find `grubx64.efi` — `Failed to open \EFI\BOOT\grubx64.efi - Not Found`. That
message means the signature was accepted, which is the whole question. Only
`Security Violation` / `Access Denied` *before* it is a failure of this step.

*Failure signature:* `Security Violation` on the shim contradicts `db` being 4353
bytes — re-check step 4 before believing it.

## 6. A revoked binary is refused

The other half, and the harder one to source: you need a binary whose Authenticode
hash is in the shipped `dbx`. Confirm a candidate *before* trusting the result — the
dbx holds PE Authenticode hashes, not file checksums:

```bash
# on the desk, not the test machine
python3 scripts/parse-efi-auth.py --count-esl files/microsoft-uefi-certs/dbx.esl
#  -> 443            (--count-esl takes the BARE esl; on a .auth it reports
#                     "malformed signature list", which is the wrapper, not a fault)

pesign --hash --in candidate.efi --digest_type sha256   # pesign package
#  -> compare that Authenticode hash against the revocation list; a plain
#     sha256sum of the file will never match, the list holds PE hashes
```

Good candidates: a pre-BootHole (CVE-2020-10713) shim or GRUB, or a Windows 7/8-era
`bootmgfw.efi`.

- [ ] The revoked binary is **refused** under enforcement

If you cannot source one, record that as untested rather than passed.

## 7. FIDO2 LUKS unlock under a sealed UKI

Needs the LUKS install from step 2. The `rd.luks.options=fido2-device=auto` bake is
verified statically; the unlock never has been.

```bash
mise fido2:enroll-luks     # then reboot
```

- [ ] Reboot prompts for a key touch and unlocks with **no passphrase**

*Failure signature:* a passphrase prompt means the cmdline bake did not take effect —
and because a UKI freezes its cmdline, that cannot be fixed on the installed system;
it needs a new sealed image.

## 8. Upgrade and rollback, still enforcing

```bash
bootc upgrade && systemctl reboot
bootctl status | grep -i 'secure boot'     # still enabled (user)
systemctl is-system-running                # running, not degraded
bootc rollback && systemctl reboot
```

- [ ] Upgrade boots enforcing and healthy
- [ ] Rollback boots enforcing and healthy

The upgraded image must be *newer than the installed one* or `bootc` reports no update
and this proves nothing — check `bootc status` before and after.

## 9. If the machine will not boot

Re-enter firmware setup, use the vendor's "Clear Secure Boot keys" / "Restore factory
keys". That returns the firmware to Setup Mode, from which you can re-enrol or leave
Secure Boot off. Nothing in this procedure writes anything that survives that reset.

## Reporting

Paste into the release issue — an unrecorded pass is indistinguishable from an
untested item, which is how #438 stayed invisible for months:

```
machine:        <vendor/model, firmware version>
ISO sha256:     <from step 0>
payload:        <image Created + digest>
step 3 prompt:  <verbatim menu text; asked / did not ask>
step 4 sizes:   PK … KEK … db … dbx …   (before: …)
step 5 MS bin:  <what you booted> → loaded / refused
step 6 revoked: <binary> → refused / could not source
step 7 FIDO2:   touch-unlock / passphrase / not in scope
step 8:         upgrade … rollback …
devices lost:   <none, or which>
```
