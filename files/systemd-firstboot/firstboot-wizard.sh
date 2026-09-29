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

# The unit runs StandardError=tty so the wizards' own messages ("password too
# weak", homectl's errors) stay in front of the human at the VT. That also sent
# this script's diagnostics there and nowhere else, which made a first boot that
# went wrong undiagnosable after the fact: `journalctl -u krytis-firstboot`
# showed only systemd's own Started/exited lines, never a reason. Log to both --
# the tty for whoever is sitting there, the journal for whoever looks later.
log() {
    echo "krytis-firstboot: $*" >&2
    printf 'krytis-firstboot: %s\n' "$*" \
        | systemd-cat -t krytis-firstboot -p warning 2>/dev/null || true
}

# Same idea at info level, for the two facts that make a later "why did/didn't
# this run?" answerable: that it started at all, and that it finished.
note() {
    printf 'krytis-firstboot: %s\n' "$*" \
        | systemd-cat -t krytis-firstboot -p info 2>/dev/null || true
}

note "starting first-boot wizard on $(tty 2>/dev/null || echo 'unknown tty')"

# Keymap and timezone are optional and must not gate account creation, which is
# the step that makes the machine usable at all -- hence no `set -e`: a failure
# here is logged and stepped over.
#
# No --prompt-locale (locale is baked by config/locale-data.bst) and no
# --prompt-root-password (root stays locked as root:!unprovisioned).
if ! systemd-firstboot --prompt-keymap-auto --prompt-timezone \
        --welcome=no --mute-console=yes; then
    log "keymap/timezone step failed, continuing"
fi

# --member-of=wheel grants sudo (%wheel ALL=(ALL) ALL, from freedesktop-sdk's
# vm/config/sudo.bst) without prompting for group membership: the first-boot user
# IS the admin account. --prompt-groups=no is what keeps that value -- were the
# groups prompt left on, an interactive answer would overwrite memberOf wholesale.
#
# --auto-resize-mode=off --disk-size=50% is the #996 decision. Do not restore
# shrink-and-grow: on systemd 261 that is already homed's default for a
# LUKS2+btrfs home ("Defaults to shrink-and-grow, if LUKS2/btrfs is used,
# otherwise is off" -- man homectl), i.e. what homectl firstboot would produce
# unprompted, and it is actively harmful here. It shrinks the image on every
# clean logout; the shrink is btrfs block-group relocation so it scales with
# data in use (11 minutes measured on real hardware), and while it runs
# pam_systemd_home blocks, so the next login dies with the greeter's "Login
# service stopped responding. Restart greetd." Every upstream thread on homed
# resize latency reaches the same workaround -- see docs/skills/pam.md
# § A logout shrink blocks the next login, and its Prior art subsection.
#
# --disk-size=50% replaces homed's own default of 85% of free space. The size
# matters much more once auto-resize is off, because the LUKS2 image is
# allocated in full at creation, not sparsely (verified: `stat` reports
# allocated blocks equal to apparent size), so the value chosen here is
# consumed on disk immediately and nothing reclaims it later. Sizing is
# relative to FREE space on the backing filesystem at creation time
# (homework-luks.c calculate_initial_image_size uses statfs f_bavail), so it
# self-scales and cannot over-commit. Half is left for the OS: bootc
# deployments, system flatpaks and root container storage measured ~101 GB on
# a well-used krytis machine. The asymmetry decides the direction of the
# guess: growing later is a cheap allocation, shrinking is the multi-minute
# relocation above, so start small and grow.
#
# --rebalance-weight=off is redundant but kept explicit: homectl already
# forces rebalanceWeight to off whenever --disk-size= is given
# (homectl.c parse_disk_size_field), and that implicit coupling is exactly the
# kind of thing that changes without notice.
#
# Adjusting the size afterwards needs `homectl resize <user> <size>`, which is
# admin-authenticated (org.freedesktop.home1.resize-home is auth_admin_keep
# even for an active session, and there is no by-owner variant). noctalia is
# the polkit agent, so that prompt is graphical. A GUI control for it is #998.
if ! homectl firstboot --prompt-new-user --prompt-shell=no \
        --prompt-groups=no --member-of=wheel \
        --auto-resize-mode=off --rebalance-weight=off --disk-size=50% \
        --mute-console=yes; then
    log "initial user creation failed"
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
    note "setup complete, wrote ${MARKER}; will not prompt again"
else
    log "no regular user yet, will prompt again next boot"
fi
