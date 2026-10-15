#!/usr/bin/bash
# Remove fisherman's install-time scratch data from the physical root
# (krytis#1282). Runs from krytis-fisherman-scratch-cleanup.service, in a
# private mount namespace.
#
# On a live ISO fisherman puts its scratch dir on the target disk, then deletes
# it only after unmounting the target, so the delete hits an empty mount point
# in the live session and the data stays on disk: a container store and an OCI
# export of the OS image, ~11G. No secrets, just space.
set -euo pipefail

S=/sysroot/.fisherman-scratch
SIZE=$(du -sh "$S" 2>/dev/null | cut -f1 || echo unknown)

# `bind`: change only this mount's flag (see fisherman-cleanup.sh).
mount -o remount,bind,rw /sysroot
rm -rf --one-file-system "$S"

echo "Removed ${SIZE} of leftover installer scratch data from the physical root (${S})."
