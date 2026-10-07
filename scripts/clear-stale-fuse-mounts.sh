#!/usr/bin/env bash
# Unmount dead buildbox-fuse mounts under ~/.cache/buildstream on a persistent
# runner (krytis-vps). Run at the start of every job that builds there:
# cache-warm.yml and build-changed.yml.
#
# A killed build leaves its mounts behind: an OOM-killed or cancelled job's
# mountpoint stays present with its server gone, and every later `df` on the box
# then exits 1 with "Transport endpoint is not connected". That is how run
# 34696760836 failed before reaching the build. See docs/skills/ci-runner.md
# § A killed build leaves FUSE mounts that break every later `df`.
set -euo pipefail

STALE=0
for m in $(awk '$2 ~ /buildstream/ && $3 ~ /fuse/ {print $2}' /proc/self/mounts); do
  # `stat -f` (statfs), NOT `stat`. A dead FUSE mount still answers stat() from
  # the dentry cache: run 34746389718 reported "Cleared 0" while df failed on a
  # mount listed right there in /proc/self/mounts, because stat() succeeded on
  # it. statfs() is what df itself calls and what returns ENOTCONN.
  if ! timeout 5 stat -f "${m}" >/dev/null 2>&1; then
    echo "Unmounting stale FUSE mount: ${m}"
    # umount -l first: fusermount is not installed on the VPS (no `fuse`
    # package; buildbox-fuse ships its own), so the fusermount path never
    # fired and only the fallback ever worked.
    umount -l "${m}" 2>/dev/null || fusermount -u "${m}" 2>/dev/null || true
    STALE=$((STALE + 1))
  fi
done
echo "==> Cleared ${STALE} stale FUSE mount(s)."
