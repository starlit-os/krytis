# Investigate ESP bootloader updates

**Issue:** #1328 · **Status (2026-11-02): done.** The loader is updated after an upgrade by
systemd's `systemd-boot-update.service`, not by bootc. On a LUKS root that never happened,
because gpt-auto generates no ESP mount there. `config/esp-automount.bst` now generates it,
and `mise run esp-update-test` proves the update on an encrypted install (step 5).

#1328 asks whether a sealed krytis install ever picks up a newer signed systemd-boot after
`bootc upgrade`. Two documents disagree. The issue assumes bootc never touches the loader.
`docs/skills/secure-boot.md` § *2. `targetImgref`, not just the store key* says the first
upgrade "overwrites the signed UKI **and signed systemd-boot**". Neither cites a
measurement.

## Non-goals

- **Designing or shipping the fix.** If the loader is stale, this plan ends with a
  measured answer and #1328 re-sized for the fix. The fix writes the boot path and touches
  the signing chain, so it needs the Breakage Gate and the Security Gate before any code.
- **shim.** krytis's chain has no shim. Dakota's file list (projectbluefin/dakota#1781)
  doesn't carry over; only its update mechanism does.

## Step 0: what bootc v1.17.3 does on upgrade (done)

The source is read at the pinned tag (`elements/core/bootc.bst`,
`v1.17.3-0-g6d7893f2`). Prediction: **bootc never rewrites the loader on upgrade.**

- `bootloader::install_systemd_boot()` is the only place that runs `bootctl install`. It
  has exactly one caller, `bootc_composefs/boot.rs` `install_composefs_bootloader()`,
  which runs only at install.
- `bootc upgrade` goes `update.rs` `upgrade_composefs()` → `do_upgrade()` →
  `setup_composefs_uki_boot(BootSetupType::Upgrade(..))`. It mounts the ESP writable
  (`mount_esp_writable`) and writes three things:
  - the UKI and its addons, via `write_pe_to_esp` into `EFI/Linux/bootc/`
  - staged global addons
  - loader entries, via `write_systemd_uki_config`

  It never reads `/usr/lib/systemd/boot/efi/`, and it never writes `EFI/systemd/` or
  `EFI/BOOT/`.
- No upgrade path calls `bootctl update` or `bootupctl`. The `bootctl` mentions under
  `bootc_composefs/` are comments.

The secure-boot.md claim that an upgrade overwrites the signed systemd-boot therefore
contradicts the source. Step 3 settles it.

## Step 0b: the image already ships an update unit; on `adora` it no-ops (done)

Found while reading. This changes the design question in #1328.

- **systemd's `systemd-boot-update.service` is enabled in the image.** It is in
  `/etc/systemd/system/sysinit.target.wants/`, via `90-systemd.preset:23`. Every boot it
  runs `ExecStart=bootctl --variables=no --graceful update`. Checked in
  `localhost/krytis:sealed`.
- **On `adora` it finds no ESP and exits 0.** Live on `adora` (image `26.08.202611011748`),
  from `journalctl -b -u systemd-boot-update.service`:

  ```
  bootctl[809]: Couldn't find EFI system partition, skipping.
  ```

  The unit reports `active (exited)`, status 0, so nothing ever flags it. `/boot` and
  `/efi` exist as empty directories with nothing mounted on them. That matches the
  unmounted ESP already noted in `docs/skills/bootc-vm.md` and `docs/skills/secure-boot.md`
  (the `fwupdtool` and `dbx-append` notes).

So #1328's "check first whether `bootctl update --graceful` from a unit is enough" is half
answered: the unit already exists. Step 3 found it works on a plain root and is blind on
a LUKS one. What's left is whether it would be
enough once it can see the ESP. systemd v262's `src/bootctl/bootctl-install.c` sets two
limits:

- **The update is version-gated.** `version_check()` (lines 454–490) skips a target when
  the version in place is the same ("same boot loader version in place already") or newer.
  Under `--graceful` that skip exits 0 (line 884). A same-version change would never reach
  installed machines. Acceptable since #447 decided keys never rotate, and SBAT isn't
  enforced without shim.
- **It only updates an ESP where `/EFI/systemd/` is non-empty** (lines 1511–1523,
  1658). If krytis's install leaves that directory empty, the unit skips everything,
  including `BOOTX64.EFI`. Step 2 records what is there.

## Step 1: the real-machine data point (done) and the VM image pair

**Real machine (`adora`, ThinkPad T14 Gen 4, Secure Boot `enabled (user)`):**

| | Value | Source |
|---|---|---|
| Booted image | `26.08.202611011748` | `/etc/os-release` |
| systemd-boot the image ships | `262.1`, sha256 `79a1a899…dca08dbcb` | `LoaderInfo` string in `/usr/lib/systemd/boot/efi/systemd-bootx64.efi` |
| systemd-boot the firmware ran | **`260.2`**, from `\EFI\BOOT\BOOTX64.EFI` | `bootctl status` → Current Boot Loader |
| systemd-stub the firmware ran (inside the UKI) | `262.1` | `bootctl status` → Current Stub |

The UKI moved forward with each upgrade. The loader is two systemd releases behind. This
is one machine with an unknown install date, and we don't know whether
`EFI/systemd/systemd-bootx64.efi` exists alongside `BOOTX64.EFI` or what it contains.
Steps 2 and 3 control both.

**VM pair (gate passed):**

| Tag | systemd-boot in the image | sha256 |
|---|---|---|
| `26.08.202610111750-sealed` | `261.3` | `c00179a1…a1f935` |
| `26.08.202611011748-sealed` | `262.1` | `79a1a899…dca08dbcb` (same as `adora`'s `/usr`) |

Both the hashes and the versions differ. A version bump is what `bootctl update` acts on,
so this pair tests bootc and also tests what the existing unit would do if it could see
the ESP.

## Step 2: install the older image (done, via `generate-disk`)

The ISO path fails before it touches the disk. bootc-installer's 2026-10-31 release makes
fisherman demand `/etc/bootc-installer/media-input.json` on every krytis ISO (#1479). So
the install was `bootc install to-disk`, the same `install_systemd_boot()` →
`bootctl install` the ISO path reaches:

```bash
mise run pull-keys
SEALED_TAG=ghcr.io/starlit-os/krytis:26.08.202610111750-sealed mise run generate-ovmf-vars
mise run generate-disk --image ghcr.io/starlit-os/krytis:26.08.202610111750-sealed \
    --disk /var/tmp/krytis-install.img
```

As installed: `EFI/systemd/systemd-bootx64.efi` and `EFI/BOOT/BOOTX64.EFI` are both
`c00179a1971ff674…`, systemd-boot 261.3, byte-identical to the old image's signed binary.
There is one UKI in `EFI/Linux/bootc/`.

**Difference from the field:** the root is plain btrfs, not LUKS. Step 3 shows this
matters.

## Step 3: upgrade and measure again (done)

```bash
mise run upgrade-test --to ghcr.io/starlit-os/krytis:26.08.202611011748-sealed --keep
```

The guest switched and rebooted. The new deployment (`StarlitOS Krytis 26.08.202611011748`
on its console) booted under enforcement. On the kept `disk.raw`:

| File | Before | After |
|---|---|---|
| `EFI/systemd/systemd-bootx64.efi` | 261.3 `c00179a1…` | **262.1 `79a1a899…`**, the new image's signed binary |
| `EFI/BOOT/BOOTX64.EFI` | 261.3 `c00179a1…` | **262.1 `79a1a899…`** |
| `EFI/systemd/systemd-boot-fallbackx64.efi` | absent | 261.3 (v262 bootctl's fallback rotation) |
| `EFI/Linux/bootc/` | 1 UKI | 2 UKIs (control: the upgrade wrote the ESP) |

Who copied the loader: the fallback file only exists in v262's `bootctl update`, and bootc
has no such code (step 0). The serial log shows `boot.mount - EFI System Partition
Automount` and `systemd-boot-update.service` on both boots. On the second boot that unit
ran the new deployment's bootctl. So the loader was updated **by the boot-time unit, on the
first boot after the upgrade**. It worked here because gpt-auto found the ESP.

**Why `adora` differs: a LUKS root** (read from source; the decisive root-run log is still
missing):

- bootc's initramfs links `/run/systemd/volatile-root` to the device under `/sysroot`. On
  `adora` that is `/dev/block/253:0` → `dm-0`, the dm-crypt mapping.
- systemd v262's `blockdev_get_root()` uses `volatile-root` as is; only its other branch
  traces dm-crypt.
- So `systemd-gpt-auto-generator` dissects `dm-0`, finds no GPT (`-ENOPKG`, logged at debug
  level only) and creates no ESP mount. That matches `boot.automount` = `not-found` on
  `adora`.

To confirm (needs root, not yet run):

```bash
D=$(mktemp -d); sudo env SYSTEMD_LOG_LEVEL=debug SYSTEMD_LOG_TARGET=console \
  /usr/lib/systemd/system-generators/systemd-gpt-auto-generator "$D/n" "$D/e" "$D/l"
```

A `mise run luks-install-test` disk run through `upgrade-test` would show it end to end.
That waits on #1479, because the LUKS install path is the ISO.

**Harness note:** the post-upgrade report (`phase=post`) never reached the serial log in
this run. The guest powered itself off 331 s into the second boot, which fits the probe's
300 s `is-system-running --wait` timeout on a disk with no account (first-boot wizard
pending). The loop only checks for marker lines, so it then waited out its full 1800 s
deadline. Neither affects the ESP measurement, which is read offline.

## Step 4: write-up (done in this branch, except the fix)

- `docs/skills/secure-boot.md`: corrected the "overwrites … signed systemd-boot"
  sentence. Added § The ESP's systemd-boot is updated by systemd, not bootc — and not on a
  LUKS root.
- `mise/tasks/upgrade-test`: prints the ESP loader hashes and versions before and after,
  plus the target image's, if it is local.
- Open questions for the fix (Breakage and Security Gates):
  1. ~~Make the ESP visible on LUKS~~: chose a krytis generator that recreates gpt-auto's
     ESP automount (option B on #1328), over a drop-in for `systemd-boot-update.service`
     alone, a carried bootc patch, or a custom update unit. See step 5.
  2. ~~Version gating~~: accepted. #447 decided keys never rotate (2026-11-02), so a
     same-version re-sign never needs to propagate, and SBAT isn't enforced without shim.
  3. Ordering against `dbx-append`: unchanged. `dbx-append apply` already refuses while
     any `.efi` on the ESP would be newly revoked, and on LUKS installs that refusal now
     clears by itself once the loaders update.
- #1328: result posted, re-sized for the fix.

## Step 5: the fix (done)

- `files/esp-automount/krytis-esp-automount-generator`, shipped by
  `elements/config/esp-automount.bst` in `stacks/base-system.bst`. It acts only when
  `/run/systemd/volatile-root` is a device-mapper device. It then writes gpt-auto's
  `boot.mount` and `boot.automount` (same options, fsck dependency and 120 s idle timeout)
  for the `LoaderDevicePartUUID` partition, into the normal generator directory.
- Smoke on `adora` (LUKS, unprivileged, into a temp dir): it generated units for
  `/dev/disk/by-partuuid/aa6b184e-…`, the partition `bootctl status` reports, and
  `systemd-analyze verify` was clean. In a container with no `volatile-root` it generated
  nothing.
- End to end, 2026-11-02:
  - `mise run build` and `seal-uki`, then `build-iso --sealed --debug` and
    `luks-install-test --keep`: PASS. The boot log shows
    `Set up automount boot.automount - EFI System Partition Automount` and
    `Mounted boot.mount`.
  - `mise run esp-update-test`: PASS. systemd-boot 261.3, planted on both loader paths,
    went back to the image's 262.1 (`87659802acfbae7a`) after one boot.
- New permanent gate: `mise/tasks/esp-update-test`. It needed `boot-test --in-place`,
  because `boot-test --reuse-disk` boots a reflinked copy and the update landed on a disk
  the gate never read; the first run reported a false FAIL. The ESP helpers moved to
  `mise/lib/esp.sh`, which `upgrade-test` now shares.
- Not done as a negative control in a VM: the same gate against an image without the
  generator. The pre-fix behaviour is `adora`'s (no `boot.automount`, loader 260.2 under
  a 262.1 image).

## Out of scope, found here

- `docs/skills/mise.md:13` cited `mise bst source track core/bootupd.bst`, but no
  `elements/core/bootupd.bst` exists. Fixed in this branch to `core/bootc.bst`.
- #1479: every krytis ISO install fails since the 2026-10-31 bootc-installer release.
