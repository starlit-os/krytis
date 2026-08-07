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

**Preserved:** all five certificates Microsoft publishes for `db`
([microsoft/secureboot_objects](https://github.com/microsoft/secureboot_objects)
`PreSignedObjects/DB/Certificates/`) are bundled into `db.auth` (#464), so
Microsoft-signed EFI binaries keep verifying after enrollment:

| Microsoft's `db` certificate | signs |
|---|---|
| Microsoft Corporation UEFI CA 2011 | shims, most third-party option ROMs |
| Microsoft Windows Production PCA 2011 | `bootmgfw.efi` on essentially every current Windows 10/11 install |
| Microsoft UEFI CA 2023 | newer third-party binaries |
| Microsoft Option ROM UEFI CA 2023 | option ROMs signed under the 2023 chain |
| Windows UEFI CA 2023 | Windows binaries signed under the 2023 chain |

That includes a Windows boot manager, so dual-boot survives. It did **not** before
#464: only two of the five were shipped, and because enrollment *replaces* the OEM's
`db` rather than merging with it, enrolling silently made an existing Windows install
unbootable — a distro `shimx64.efi` kept working (its chain is
`Microsoft Windows UEFI Driver Publisher` → `Microsoft Corporation UEFI CA 2011`, one
of the two we had) while `bootmgfw.efi`, signed under Windows Production PCA 2011, did
not.

`dbx` is enrolled alongside (#446), so binaries Microsoft has *revoked* are still
refused — the allow-list is not open-ended. Widening `db` also does not make krytis's
own unsigned artifacts acceptable: verified by enrolling this key set and then
presenting an unsigned `systemd-bootx64.efi`, which the firmware refuses with
`Access Denied -- rejected probably by Secure Boot`.

Check any specific binary before trusting it — read the chain, do not ask a verifier.
It is the *issuer* that has to be in `db`, not the leaf:

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

## 1. Record the pre-enrollment state — from the live ISO, before clearing anything

**You must install before enrollment can be triggered at all.** The `.auth` files
reach the ESP only through `bootc install`; the live ISO's own ESP has
`loader/loader.conf` and `loader/entries/` but **no `loader/keys/`** directory
(verified with `mdir` on the ISO's `EFI/efi.img`), so `secure_boot_discover_keys()`
finds nothing and the enrollment entry cannot appear in the live session. Hand-copying
the keys onto the ISO would also defeat the point: what is under test is the ESP
`bootc install` produces, which is exactly what was empty in #438.

So the live ISO has one job before the install, and this is it — capture what the OEM
shipped, while it is still there:

```bash
for v in PK KEK db dbx dbDefault KEKDefault dbxDefault; do
  printf '%-12s %s\n' "$v" "$(stat -c%s /sys/firmware/efi/efivars/${v}-* 2>/dev/null || echo absent)"
done
bootctl status | grep -i 'secure boot'
```

Order matters, and it is easy to get backwards:

1. **Disable Secure Boot** in firmware — the live ISO is unsigned by design (#371), so
   a factory-enforcing machine refuses it. Do **not** clear the keys yet.
2. Boot the live ISO and run the above. efivars are readable with Secure Boot merely
   disabled; the OEM's values are still intact.
3. Save it off the machine — photograph the screen or write to the second USB. You are
   about to overwrite these variables.

Clearing the Platform Key first would take the very values step 4 compares against.

Two states seen in practice that the obvious expectation does not cover:

- **`dbDefault` / `KEKDefault` / `dbxDefault` may all be `absent`.** Plenty of firmware
  never populates them. They are not the baseline — the live `PK`/`KEK`/`db`/`dbx`
  values you capture here are, which is the whole reason this step exists.
- **`PK absent` while `KEK`/`db`/`dbx` are still populated** means the machine is
  *already* in Setup Mode with the previous key material intact. Clearing the Platform
  Key does not necessarily clear the rest. Enrollment is armed in that state, so if you
  have not deliberately cleared it, check whether something else did before you
  continue.

## 2. Install from the ISO

Secure Boot **off** or in Setup Mode — the live ISO is unsigned by design (#371), so an
enforcing firmware will refuse to boot the installer itself.

Choose LUKS here if step 7 is in scope. Expected: the installer completes and the
system is installed from the offline payload with no network.

*Failure signature:* `The UKI has the wrong composefs= parameter` means the embedded
payload was mutated — the ISO is bad, not the machine. Stop and rebuild.

### On a LUKS install, retag the root partition BEFORE you reboot

**Do this from the live session, while the installer's disk is still in front of you.**
A LUKS install lands **unbootable** until `tuna-os/fisherman#72` merges: fisherman types
the root partition with the generic `linux` GUID, and a sealed UKI cannot find an
encrypted root that way — the signed cmdline carries no `rd.luks.uuid`, `hostonly=no`
means the initrd has no `/etc/crypttab`, so `systemd-gpt-auto-generator` is the only
discovery mechanism and it needs the Discoverable Partitions root GUID.

Skip this and the machine boots to a plymouth splash, waits ~90 s on
`dev-gpt-auto-root.device`, then drops to emergency mode with **no passphrase prompt** —
which reads like a broken image and is not. Confirmed on hardware (#473) and reproduced
synthetically (#474).

```bash
# sudo on the lsblk calls too: FSTYPE, LABEL and PARTTYPENAME come from probing the
# device, not from sysfs, so unprivileged they come back EMPTY. A blank PARTTYPENAME
# reads exactly like a failed retag, and a blank FSTYPE hides which partition is the
# crypto_LUKS one. NAME/SIZE/TYPE/TRAN/RM need no root, which is why the USB step
# above works without it.
sudo lsblk -o NAME,SIZE,FSTYPE,PARTTYPENAME,PARTUUID   # find the crypto_LUKS partition
# It will read "Linux filesystem" (generic). Retag it — metadata only, data untouched:
sudo sfdisk --part-type /dev/nvme0n1 3 4f68bce3-e8cd-4db1-96e7-fbcaf984b709
sudo partprobe /dev/nvme0n1
sudo lsblk -o NAME,PARTTYPENAME /dev/nvme0n1           # want "Linux root (x86-64)"
```

Adjust the disk and **partition number** from your own `lsblk` output — the number is
the crypto_LUKS partition's, not always 3.

- [ ] Root partition reads `Linux root (x86-64)` before the first reboot

`mise run luks-install-test` gates this in QEMU and repairs it automatically, printing
the same warning; `--strict-installer` fails instead, which is how to check whether
fisherman#72 has landed and this subsection can be deleted.

## 3. The enrollment prompt — the item no VM can produce

Read from systemd-boot 260's own source rather than assumed, because the assumptions
here were wrong in two ways (`src/boot/boot.c`, `src/boot/secure-boot.c`):

**Setup Mode is the only hard gate.** `secure_boot_discover_keys()` returns
immediately unless the mode is SETUP or AUDIT:

```c
if (!IN_SET(secure_boot_mode(), SECURE_BOOT_SETUP, SECURE_BOOT_AUDIT))
        return EFI_SUCCESS;
```

No Setup Mode → **no menu entry at all**, whatever `loader.conf` says. "Secure Boot:
disabled" without `(setup)` is not enough; the firmware must have no Platform Key.

**The entry appears on the first boot too.** Discovery runs whenever
`secure-boot-enroll != off`, and the compiled-in default is `if-safe` — so the
first-boot oneshot that writes `manual` is not a prerequisite. It only removes the
auto-enroll behaviour, which on hardware cannot happen anyway:

```c
bool is_safe = in_hypervisor();
if (!is_safe && !force) return EFI_SUCCESS;    /* silent no-op on real hardware */
```

**Selecting the entry is not a yes/no prompt — it is an abortable countdown.**
Menu selection calls `secure_boot_enroll_at(..., force=true)`, which prints:

```
Enrolling secure boot keys from directory: \loader\keys\auto
Warning: Enrolling custom Secure Boot keys might soft-brick your machine!
Enrolling in Ns, press any key to abort.
```

**Press nothing.** Any keypress aborts. Let it run out and it enrols, then reboots
itself (`ENROLL_ACTION_REBOOT`).

Pre-flight from the installed system before you reboot into it:

```bash
bootctl status | grep -i 'secure boot'            # want: disabled (setup)
ls /boot/loader/keys/auto/                        # PK KEK db dbx .auth must all be here
grep secure-boot-enroll /boot/loader/loader.conf  # absent on boot 1 is fine
```

Record verbatim:

- [ ] Exact wording of the menu entry (expected `Enroll Secure Boot keys: auto`)
- [ ] The countdown text and how many seconds it gave
- [ ] That it rebooted itself rather than continuing to boot

*Failure signature:* no entry at all → in order of likelihood, the firmware is not in
Setup Mode (check `bootctl status` says `(setup)`), or `\loader\keys\auto\` is missing
from the ESP. `loader.conf` is the *least* likely cause, since the default already
permits discovery.

## 3b. The first-boot wizard — the machine has no account until you do this

Since #487 the initial account is created by `krytis-firstboot.service`, prompting on
**tty5**. Nothing else creates a user, so an image built before #487 gives you an
installed system with no way in — which is what makes an older `:sealed` unusable for a
full hardware run regardless of how well its boot chain verifies.

**The greeter comes up first and does not mention this.** `greetd`/`noctalia-greeter`
owns vt1 and shows a login screen immediately, with nothing to log into. That is a
known, accepted rough edge (`docs/design/first-boot-setup.md` § Consequence), not a
fault to report — the wizard is simply somewhere else:

```
Ctrl+Alt+F5
```

In order, on that VT:

1. `systemd-firstboot --prompt-keymap-auto --prompt-timezone` — keymap and timezone.
   Locale is baked (`config/locale-data.bst`) and root stays locked
   (`root:!unprovisioned`), so neither is asked.
2. `homectl firstboot --prompt-new-user` — the initial account, created as a
   **systemd-homed** user: encrypted home, FIDO2-login-ready, and `--member-of=wheel`
   so it is the admin account. `--prompt-shell=no --prompt-groups=no` are deliberate;
   answering a groups prompt would overwrite `memberOf` wholesale.

- [ ] tty5 shows the wizard, not a bare `login:` prompt
- [ ] Keymap/timezone accepted
- [ ] The account is created, and `homectl list` shows it
- [ ] Switching back to vt1 (Ctrl+Alt+F1) lets you log in as that user
- [ ] `getent passwd <name>` resolves, and `id <name>` shows `wheel`

**Deliberately not `ConditionFirstBoot=yes`, so an unanswered prompt is recoverable.**
`Type=exec` means the start job completes once the wizard is *running*, not once it is
answered — boot reaches `graphical.target` with the prompt still waiting, and
`mise run boot-test`'s health assertion passes on an unanswered machine. If you skip or
abort it, no marker is written and **the next boot asks again**; that is the designed
behaviour, not a retry bug.

*Failure signature:* tty5 shows a normal `login:` prompt instead of the wizard →
`krytis-firstboot.service` did not start, or a regular user already exists (`homectl
firstboot` returns without prompting once one does — systemd's `has_regular_user()`).
Check `journalctl -u krytis-firstboot`; since #523 its diagnostics go to the journal as
well as the VT, so a failure is readable after the fact rather than only visible on a
screen you have since switched away from.

## 4. Post-enrollment state — replaced, not merged

```bash
bootctl status | grep -i 'secure boot'      # expect: Secure Boot: enabled (user)
for v in PK KEK db dbx; do
  printf '%-5s %s\n' "$v" "$(stat -c%s /sys/firmware/efi/efivars/${v}-* 2>/dev/null || echo absent)"
done
```

Compare with step 1. Expected, in the same order as the sizes `virt-fw-vars` reports
in the VM tests: `PK` 1254, `KEK` 1263, `db` 8891, `dbx` 21292 — krytis's own, *not*
the OEM's, and `dbx` **present** (that is #446 landing on real firmware; a missing
dbx means every revoked Microsoft-signed binary still verifies).

**Add 4 to each when reading `/sys/firmware/efi/efivars/`** — efivarfs prefixes every
variable with a 32-bit attributes field, so `db` reads as 8895 there, not 8891. A
uniform 4-byte excess is the prefix, not a corrupt list.

Replaced-versus-merged is arithmetic, not judgement. Take your step 1 numbers and work
out both answers *before* you enrol, so the post-enrollment read is a lookup:

| | reads (efivars, incl. +4) |
|---|---|
| replaced | `PK` 1258 · `KEK` 1267 · `db` 8895 · `dbx` 21296 |
| merged | step-1 data size + krytis's payload + 4 |

Worked example from a real machine whose step 1 read `KEK 2549, db 8079, dbx 18352`:
`db` becomes **8895** if replaced, **16970** if merged. There is no ambiguity between
those two numbers.

**`db` may shrink or grow, and either is expected.** Since #464 krytis enrols all five
of Microsoft's `db` certificates plus its own, so on a typical machine the replaced `db`
lands *close to* what the firmware shipped — the difference is krytis's cert plus
whatever OEM-specific entries the vendor added. What matters is that it equals krytis's
payload exactly, not the direction it moved.

Before #464 krytis shipped only two of the five, so this step's expected `db` was 4357
and enrolling made a dual-boot machine's Windows unbootable. If you are reading an
older image, that is still true of it.

`dbx` normally *grows* (krytis ships 443 revocations, typically more than the firmware
shipped with), which is the one direction where replacing is strictly an improvement.

- [ ] `db` size matches krytis's, so OEM defaults were replaced not merged
- [ ] Every device still initialises — no missing NIC, GPU, or add-in card

## 5. A Microsoft-signed binary still runs

The *only* real test of bundling the Microsoft CAs into `db.auth`; no offline
MS-signed binary is available to the VM path.

**Either a distro `shimx64.efi` or a Windows boot manager should run** — since #464
krytis enrols all five of Microsoft's `db` certificates, so both chains are covered:

| binary | chains to | in `db` |
|---|---|---|
| distro `shimx64.efi` | `Microsoft Windows UEFI Driver Publisher` → `Microsoft Corporation UEFI CA 2011` | yes |
| `bootmgfw.efi` (Windows 10/11) | `Microsoft Windows Production PCA 2011` | yes, since #464 |

**A refusal here is now a defect, not the documented state.** Before #464 a Windows
entry being refused was expected — we shipped two of five and Production PCA 2011 was
one of the omissions. That is fixed, so if a Microsoft-signed binary is refused, record
which CA signed it and treat it as a finding against `db.auth`, not as a known gap.
Confirm what you have before booting it, remembering that it is the *issuer* that has
to be in `db`, not the leaf:

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
permanently — and is what to do if the stick ever had a hybrid ISO written to it:

```bash
D=/dev/sdX                                   # CONFIRM first; sda is not a stable name
sudo umount ${D}* 2>/dev/null; true
sudo wipefs -a "$D"                          # clears iso9660 + GPT + MBR signatures
printf 'label: gpt\ntype=uefi, name="MSTEST"\n' | sudo sfdisk "$D"
sudo partprobe "$D"
sudo mkfs.vfat -F32 -n MSTEST "${D}1"

# Populate without mounting — mtools writes straight to the partition:
sudo mcopy -i "${D}1" -s /path/to/EFI ::
sudo mdir -i "${D}1" ::/EFI/BOOT             # want BOOTX64 EFI <size>
```

`sfdisk`, not `sgdisk` — util-linux is already a dependency and `gdisk` may not be
installed. `type=uefi` is sfdisk's alias for `c12a7328-f81f-11d2-ba4b-00a0c93ec93b`;
omitting `size=` fills the device.

Confirm the result with **`sudo`** — see the note in step 2: unprivileged, `FSTYPE`
and `PARTTYPENAME` come back empty and a correctly prepared stick looks unformatted.
`udevadm info --query=property --name=/dev/sdX1` reads the udev database instead and
works without root, which is a useful cross-check when the two disagree.

Boot the second USB from the firmware boot menu, under enforcement.

- [ ] The shim loads
- [ ] A Windows entry, if the machine has one, also loads — record which CA signed it

**Expected success looks like a shim error.** A standalone shim verifies, starts, then
fails to find `grubx64.efi` — `Failed to open \EFI\BOOT\grubx64.efi - Not Found`. That
message means the signature was accepted, which is the whole question. Only
`Security Violation` / `Access Denied` *before* it is a failure of this step.

*Failure signature:* `Security Violation` on either binary contradicts `db` being 8895
bytes — re-check step 4 before believing it. If step 4 checked out and a Microsoft-signed
binary is still refused, that is a real finding: capture the issuer CN and file it
against `db.auth`, since all five of Microsoft's `db` CAs are supposed to be enrolled.

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

**Check the image first — this step was impossible until #476.** `libfido2.so.1` was
missing from every initrd we built (dracut cannot see a `dlopen`), so FIDO2 unlock
silently fell back to a passphrase on every machine. Confirm the image you installed
actually carries it, or this step tests nothing:

```bash
# On the installed system:
lsinitrd /boot/EFI/Linux/*.efi 2>/dev/null | grep libfido2 || \
  echo "MISSING — image predates #476, re-test with a newer sealed build"
```

```bash
mise fido2:enroll-luks     # then reboot
```

- [ ] Reboot prompts for a key touch and unlocks with **no passphrase**

*Failure signature:* a passphrase prompt has **two** possible causes, and they need
different fixes:

1. **`libfido2.so.1` absent from the initrd** (#473) — `systemd-cryptsetup` `dlopen`s
   it, fails, and falls through to a passphrase. `cryptsetup.c` returns `EAGAIN` and
   clears the FIDO2 args, so the fallback is silent by design. Check with the command
   above *before* suspecting anything else; the build-time assertion in
   `elements/core/initramfs.bst` makes this impossible on images built after #476.
2. **The cmdline bake did not take effect** — and because a UKI freezes its cmdline,
   that cannot be fixed on the installed system; it needs a new sealed image.

Distinguish them by reading the frozen cmdline: `cat /proc/cmdline | tr ' ' '\n' |
grep luks`. If `rd.luks.options=fido2-device=auto` is there, the bake worked and cause
1 is the one to chase.

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
