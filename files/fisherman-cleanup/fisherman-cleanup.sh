#!/usr/bin/bash
# Remove what fisherman's first-boot TPM2 staging left on the physical root
# (krytis#1280). Runs from krytis-fisherman-cleanup.service, in a private mount
# namespace.
#
# fisherman writes the unit, its wants-link and a key file holding the LUKS
# passphrase under its install mount. On a composefs install that is the
# physical root (/sysroot), never mounted as the deployment's /etc or /usr, so
# the unit never runs and nothing shreds the key.
set -euo pipefail

# `bind` changes only this mount's flag. A plain `remount,rw` also tries the
# btrfs superblock and fails with "mount point is busy" (measured 2026-10-15).
mount -o remount,bind,rw /sysroot

rm -f /sysroot/etc/fisherman/tpm2-enroll.key \
      /sysroot/usr/lib/systemd/system/fisherman-tpm2-enroll.service \
      /sysroot/etc/systemd/system/multi-user.target.wants/fisherman-tpm2-enroll.service

# The parents were created for these files alone; the physical root has no
# /etc or /usr of its own. rmdir only removes them if empty.
for d in /sysroot/etc/fisherman \
         /sysroot/etc/systemd/system/multi-user.target.wants \
         /sysroot/etc/systemd/system /sysroot/etc/systemd /sysroot/etc \
         /sysroot/usr/lib/systemd/system /sysroot/usr/lib/systemd \
         /sysroot/usr/lib /sysroot/usr; do
    rmdir "$d" 2>/dev/null || true
done

# Deleting does not erase the old blocks on btrfs, and snapshots or backups
# may hold copies, so only a new passphrase makes them worthless.
echo "Removed a plain-text copy of the disk passphrase that the installer left behind." \
     "Change the passphrase with 'sudo cryptsetup luksChangeKey <root partition>'." \
     "See https://github.com/starlit-os/krytis/blob/main/docs/disk-passphrase-leak.md"
