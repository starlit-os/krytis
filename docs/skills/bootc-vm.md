# bootc VM Boot Debugging

Load when the VM fails to boot, diagnosing initramfs failures, or working on
`elements/core/initramfs.bst`.

## Composefs boot chain

```
systemd-gpt-auto-generator   ← detects GPT type 4f68bce3-e8cd-4db1-96e7-fbcaf984b709
  └── generates sysroot.mount (mounts btrfs at /sysroot; no root= karg needed)
        └── bootc-root-setup.service
              └── /usr/lib/bootc/initramfs-setup setup-root
                    └── mounts EROFS composefs image over /sysroot
                          └── initrd-switch-root.service
                                └── systemctl switch-root /sysroot
```

`bootc-root-setup.service` has `ConditionKernelCommandLine=composefs` — it only
runs when `composefs=<hash>` is in the kernel command line (set by `bootc install`).
If this service is skipped or absent, `/sysroot` stays as raw btrfs (no `/usr/`),
and `initrd-switch-root.service` fails with "no init found".

## Known fix: dracut bootc module unit placement

The bootc dracut module places `bootc-root-setup.service`'s wants symlink at
`/initrd-root-fs.target.wants/` (initramfs root) instead of
`/usr/lib/systemd/system/initrd-root-fs.target.wants/`. systemd doesn't look at
the root level, so the service is never pulled in.

**Fix** (already applied in `elements/core/initramfs.bst`): write a dracut.conf.d
snippet before running dracut:

```bash
printf 'systemdsystemconfdir=/etc/systemd/system\nsystemdsystemunitdir=/usr/lib/systemd/system\n' \
  | tee "%{install-root}/usr/lib/dracut/dracut.conf.d/30-bootcrew-fix-bootc-module.conf" \
       "/usr/lib/dracut/dracut.conf.d/30-bootcrew-fix-bootc-module.conf"
```

This tells the bootc module where to install its systemd units.

## Inspecting the initramfs

```bash
# List all contents
lsinitrd /run/media/lily/EFI-SYSTEM/EFI/Linux/bootc_composefs-<hash>/initrd

# Read a specific file out of the initramfs
lsinitrd <initrd-path> -f usr/lib/systemd/system/bootc-root-setup.service

# Check which dracut modules are loaded
lsinitrd <initrd-path> -f usr/lib/dracut/modules.txt

# Check kernel modules are present
lsinitrd <initrd-path> | grep -E 'erofs|overlay'
```

## Btrfs disk layout (bootc composefs)

```
/                      btrfs root
├── boot/              EFI stubs, boot files
├── composefs/         EROFS images (mode 700 — root only)
│   └── <hash>         the composefs image for the active deployment
└── state/
    ├── deploy/
    │   └── <hash>/
    │       ├── etc/   writable /etc overlay for this deployment
    │       └── var/   writable /var
    └── os/
```

The full OS (`/usr/`, `/bin/`, etc.) exists only inside the composefs EROFS image.
If composefs doesn't mount, `/sysroot` has no init and switch-root fails.

**Modifying /etc from the host:** the overlay at
`/run/media/lily/root/state/deploy/<hash>/etc/` is writable btrfs (root-owned).
This is the live `/etc` for that deployment — changes here survive reboot.
Useful for setting a root password or unlocking accounts without rebuilding.

## Boot debug techniques

### Get a shell before switch-root

Add to the kernel command line (edit the loader entry on the EFI partition):

```
rd.break=switch-root
```

This triggers `breakpoint-pre-switch-root.service`, which drops a `/bin/sh` shell
on the console **without requiring any password**. At this point composefs is
already mounted at `/sysroot`.

To set a root password from this shell:

```sh
mount --bind /proc /sysroot/proc
mount --bind /dev  /sysroot/dev
mount --bind /sys  /sysroot/sys
chroot /sysroot passwd root
exit
```

### Unlock the emergency shell

When the system drops to emergency mode and sulogin refuses login ("root account
is locked"), add:

```
systemd.setenv=SYSTEMD_SULOGIN_FORCE=1
```

This bypasses the root password check in `sulogin`. Only affects the initramfs
emergency shell (sulogin), not the real system's login manager.

### Boot failure report

On initramfs failure, dracut writes a report to `/run/initramfs/rdsosreport.txt`
in the running initramfs. It contains the full journal from the failed boot.
Accessible only from a shell in the initramfs (e.g. via `rd.break` or emergency
shell).

### GTK display vs serial console

`mise run boot-vm` uses `-display gtk` (graphical window) plus `-serial stdio`
(ttyS0). The serial console shows systemd journal output. The GTK window shows
virtual consoles (tty1–tty9). If a debug shell appears on a tty other than ttyS0,
it will only be visible in the GTK window.

## Temporary root password for VM testing

The `Containerfile` has a commented line for setting a debug root password:

```dockerfile
# Uncomment to set a temporary root password for VM login during debugging.
# Remove before shipping — not for production use.
# RUN echo 'root:krytis' | chpasswd
```

After uncommenting: `mise run lint && mise run generate-disk`.
