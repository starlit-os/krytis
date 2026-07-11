# Dakota Reference

Load when referencing the sibling project at `../dakota/` — to compare patterns, borrow elements, or understand lessons learned there that apply to krytis.

## What It Is

Dakota is a BuildStream 2 project producing a bootc OCI desktop image built on Freedesktop SDK + GNOME Build Meta (same foundation as krytis, with GNOME Build Meta as an extra junction). Published as `ghcr.io/projectbluefin/dakota:{testing,stable,next,btw}`.

## Lessons Mined

### `overlap-whitelist` required for base system file replacement

*Source: dakota `2063be5` — `docs(skills): document bst overlap-whitelist requirement`*

When an element provides files that are also provided by an upstream junction component (for example, `/etc/subuid` and `/etc/subgid` provided by `freedesktop-sdk.bst:components/shadow.bst`), BuildStream will throw an overlap error during composition (e.g. in a runtime compose element).

To explicitly overwrite these files, declare an overlap whitelist in the `public` block of the authoring element:

```yaml
public:
  bst:
    overlap-whitelist:
    - '%{sysconfdir}/subuid'
    - '%{sysconfdir}/subgid'
```

*Note: Replacing base system files destroys the base mappings. Whenever possible, prefer injecting changes dynamically via a hook rather than completely replacing junction files.* Krytis already uses this pattern — see `config/plymouth-theme.bst` (three `overlap-whitelist` entries for `plymouthd.conf`, `watermark.png`, `spinner.plymouth`) documented in `desktop.md` § Plymouth Boot Splash.

### bootc `install to-disk` requires explicit xfs root filesystem

*Source: dakota `1a865c6` — `fix(bootc): require xfs root filesystem in install config`*

bootc no longer defaults the root filesystem type when installing to disk. Without `[install.filesystem.root] type = "xfs"` in the bootc install config, bootc exits 1 with "No root filesystem specified," leaving the disk unpartitioned. Any boot-check or `generate-disk` task that calls `bootc install to-disk` will fail at the partition step.

Krytis uses composefs over btrfs (see `bootc-vm.md`), so this may not apply directly to the default boot path — but any loopback/test install that uses a plain xfs root needs this config.

### bootc loop-device boot-check: PARTSCAN + host-side losetup + GPT pre-seed

*Sources: dakota `b8f1286`, `86e3778`, `56a4cf3`, `57dd31b`, `4ca43a6`, `6569694` — the full boot-check fix chain*

A multi-step root cause that took dakota many iterations to resolve. If krytis adds a `bootc install to-disk` loopback boot-check in CI, this is the sequence that works:

1. **`--via-loopback` is a trap.** It creates the loop device inside the container, but partition nodes aren't visible in time → mkfs ENOENT ("Creating rootfs: No such file or directory").
2. **Create the loop device on the host** before the container starts: `fallocate` + `losetup` on the host, pass the real block device path (`$LOOP`) to bootc instead of `--via-loopback`. The host kernel owns the partition nodes, which appear inside the container via `-v /dev:/dev`.
3. **`losetup -P` (PARTSCAN)** so `LO_FLAGS_PARTSCAN` is set — the kernel auto-creates partition nodes via uevents when sfdisk writes the table. Without `-P`, `ioctl(BLKRRPART)` returns `EINVAL` and no `/dev/loop0p3` node appears.
4. **Pre-seed the GPT** partition table (same layout bootc will use) before running the container, then `udevadm settle`. bootc's internal sfdisk then does a synchronous UPDATE of existing nodes rather than an async CREATE from scratch — the node exists when mkfs runs.
5. **`--wipe`** to let bootc overwrite the pre-seeded partition table (otherwise bootc refuses: "Detected existing partitions").
6. **Attach without `-P`, re-attach with `-P` after install.** Re-attaching `-P` on a device with an existing partition table triggers a synchronous kernel scan, reliably materialising `loop0p1/p2/p3` before the next step mounts them.
7. **`--bootloader none` means no BLS entries** — systemd-boot never writes to the ESP, so grepping `loader/entries/*.conf` always fails. Instead scan the ostree `boot.1` tree on the root filesystem: `/ostree/boot.1/default/TREEHASH/N`. Fresh install always has exactly one deployment so `sort | head -1` is deterministic.
8. **`--ipc=host` required** for the loopback install.

### xfsprogs must be a runtime dep of bootc if default fs is xfs

*Source: dakota `ceb1eb1` — `fix(ci): use ext4 for boot-check; add xfsprogs to bootc runtime deps`*

If `bootc install to-disk` defaults to xfs but the image lacks `xfsprogs`, `mkfs.xfs` fails inside the container. The fix is to add `freedesktop-sdk.bst:components/xfsprogs.bst` as a runtime dep of the bootc element. Alternatively, pass `--filesystem ext4` to `bootc install to-disk` in boot-check if the image has ext4 tools but not xfsprogs (filesystem type is irrelevant for a boot-check that only verifies deploy + boot).

### Drop stale `gtk-doc` override

*Source: zirconium-hawaii `b96b398` / [gnome-build-meta `1d96e6f`](https://gitlab.gnome.org/GNOME/gnome-build-meta/-/commit/1d96e6f43e8f6c0db4441ec2d51c1250c22275e7)*

FDSDK/gnome-build-meta resolved the gtk-doc issue upstream; the `freedesktop-sdk.bst` override that points `components/gtk-doc.bst` → `gnome-build-meta.bst:sdk/gtk-doc.bst` may now be stale. Krytis currently has this override at `elements/freedesktop-sdk.bst:32`. Verify against the current FDSDK junction ref whether it's still needed; if the upstream issue is resolved, drop it.
