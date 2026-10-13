#!/bin/sh
# ExecStart= for starlit-update.service: run `bootc upgrade` only when no
# deployment is already staged, so at most one update is staged per reboot.
#
# Staging a second update over a pending one trips bootc-dev/bootc#2422
# (open as of 2026-10-13, reproduced on krytis with bootc 1.17.1): GC drops
# the replaced deployment's OCI manifest but leaves its
# /sysroot/state/deploy/<verity>, and every later `bootc status` fails on it,
# including bootc-finalize-staged.service at shutdown. The new boot entry is
# never written and the machine reboots into the old image. The daily timer
# fires that trigger on any machine left up through two image publishes. See
# docs/skills/bootc-vm.md § A second staged update breaks bootc until the
# orphan is removed.
#
# If `bootc status` or jq fails, nothing is upgraded: the next upgrade would
# fail the same way, and skipping cannot make a broken state worse.
set -eu

status=$(bootc status --format=json)

if ! printf '%s\n' "$status" | jq -e '.status.staged == null' >/dev/null; then
  staged=$(printf '%s\n' "$status" \
    | jq -r '.status.staged.image | "\(.version // "unknown version") (\(.imageDigest // "unknown digest"))"')
  echo "An update is already staged: ${staged}. Skipping bootc upgrade until a reboot applies it."
  exit 0
fi

exec bootc upgrade
