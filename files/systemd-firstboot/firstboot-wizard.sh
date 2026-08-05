#!/bin/sh
# Krytis first-boot wizard: keymap/timezone, then the initial
# systemd-homed-managed admin account, prompted in sequence on one reserved VT.
# Driven by krytis-firstboot.service.
#
# The sequencing lives here rather than in two units because that unit is
# Type=exec: a second unit ordered After= the first would start as soon as the
# first was *exec'd*, not when it finished, and both wizards would then fight
# over the same VT. One process, two steps, in order.
#
# Safe to re-run on every boot until it completes, because both steps are
# already idempotent:
#   * systemd-firstboot skips any value already present in /etc (no --force).
#   * homectl firstboot returns without prompting once a regular user exists
#     (systemd src/home/homectl.c, has_regular_user()).
#
# See docs/design/first-boot-setup.md
set -u

MARKER_DIR=/var/lib/krytis
MARKER="${MARKER_DIR}/firstboot-done"

# Keymap and timezone are optional and must not gate account creation, which is
# the step that makes the machine usable at all -- hence no `set -e`: a failure
# here is logged and stepped over.
#
# No --prompt-locale (locale is baked by config/locale-data.bst) and no
# --prompt-root-password (root stays locked as root:!unprovisioned).
if ! systemd-firstboot --prompt-keymap-auto --prompt-timezone \
        --welcome=no --mute-console=yes; then
    echo "krytis-firstboot: keymap/timezone step failed, continuing" >&2
fi

# --member-of=wheel grants sudo (%wheel ALL=(ALL) ALL, from freedesktop-sdk's
# vm/config/sudo.bst) without prompting for group membership: the first-boot user
# IS the admin account. --prompt-groups=no is what keeps that value -- were the
# groups prompt left on, an interactive answer would overwrite memberOf wholesale.
if ! homectl firstboot --prompt-new-user --prompt-shell=no \
        --prompt-groups=no --member-of=wheel --mute-console=yes; then
    echo "krytis-firstboot: initial user creation failed" >&2
fi

# Stop prompting only once a regular user really exists. A skipped or aborted
# prompt deliberately leaves the marker absent so the next boot asks again,
# rather than stranding the machine with no account and a locked root.
#
# The upper bound must stay well above 60000: systemd-homed allocates its
# managed users from 60001-60513, so a homed user is NOT in the usual
# 1000-60000 range. 65534 (nobody) is excluded.
if getent passwd | awk -F: '$3 >= 1000 && $3 < 65534 { found = 1 } END { exit !found }'; then
    mkdir -p "${MARKER_DIR}"
    : > "${MARKER}"
else
    echo "krytis-firstboot: no regular user yet, will prompt again next boot" >&2
fi
