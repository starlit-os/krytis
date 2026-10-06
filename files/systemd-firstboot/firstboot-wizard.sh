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
#     The two values a fresh boot pre-sets, /etc/vconsole.conf and /etc/localtime,
#     are removed below only while they are still those defaults, so an answer
#     from an earlier boot is never discarded.
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
#
# #531: before this, neither prompt ever appeared. systemd-firstboot never asks
# for a value whose file already exists (should_configure() in firstboot.c is a
# bare existence check), and on a fresh boot both files already exist by the
# time this runs:
#
#   /etc/vconsole.conf  systemd's own tmpfiles.d/etc.conf has
#                       `C! /etc/vconsole.conf`, which copies the comment-only
#                       /usr/share/factory/etc/vconsole.conf into /etc during
#                       systemd-tmpfiles-setup.service. Upstream's
#                       systemd-firstboot.service is ordered before that copy;
#                       this unit runs after systemd-user-sessions.service, long
#                       after it.
#   /etc/localtime      components/tzdata.bst ships it in the image as an
#                       absolute symlink to /usr/share/zoneinfo/UTC.
#
# So remove each one just before prompting, but only while it is still that
# default. A file identical to the factory copy configures nothing. An absolute
# link to UTC is the image's: systemd-firstboot and timedatectl both write a
# RELATIVE link (../usr/share/zoneinfo/<zone>), so a real choice never matches.
# Not --force, which would also overwrite the deliberately baked locale.
#
# --prompt-keymap-auto is fine as it is: it prompts when stdout is a VT, and
# this unit's stdout is /dev/tty5. The "not on the local console" theory in
# #531 was not the cause.
FACTORY_VCONSOLE=/usr/share/factory/etc/vconsole.conf
IMAGE_LOCALTIME=/usr/share/zoneinfo/UTC
removed_vconsole=false
removed_localtime=false
if [ -f /etc/vconsole.conf ] && cmp -s /etc/vconsole.conf "${FACTORY_VCONSOLE}"; then
    rm -f /etc/vconsole.conf && removed_vconsole=true
fi
if [ "$(readlink /etc/localtime 2>/dev/null)" = "${IMAGE_LOCALTIME}" ]; then
    rm -f /etc/localtime && removed_localtime=true
fi

if ! systemd-firstboot --prompt-keymap-auto --prompt-timezone \
        --welcome=no --mute-console=yes; then
    log "keymap/timezone step failed, continuing"
fi

# A skipped prompt writes nothing. Put the defaults back rather than leave the
# files missing: timedatectl and anything that reads the link would otherwise
# see an unset zone. The next boot removes them again and re-asks, until a user
# exists.
if [ "${removed_vconsole}" = true ] && [ ! -e /etc/vconsole.conf ]; then
    cp "${FACTORY_VCONSOLE}" /etc/vconsole.conf \
        || log "could not restore /etc/vconsole.conf from ${FACTORY_VCONSOLE}"
fi
if [ "${removed_localtime}" = true ] && [ ! -e /etc/localtime ] && [ ! -L /etc/localtime ]; then
    ln -s "${IMAGE_LOCALTIME}" /etc/localtime \
        || log "could not restore /etc/localtime -> ${IMAGE_LOCALTIME}"
fi

# --member-of=wheel grants sudo (%wheel ALL=(ALL) ALL, from freedesktop-sdk's
# vm/config/sudo.bst) without prompting for group membership: the first-boot user
# IS the admin account. --prompt-groups=no is what keeps that value -- were the
# groups prompt left on, an interactive answer would overwrite memberOf wholesale.
#
# --auto-resize-mode=off --disk-size=35% is the #996 decision. Do not restore
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
# --disk-size=35% replaces homed's own default of 85% of free space. The size
# matters much more once auto-resize is off, because the LUKS2 image is
# allocated in full at creation, not sparsely, so the value chosen here is
# consumed on disk immediately and nothing reclaims it later. Measured on real
# hardware: growing one home 84G -> 150G raised `df /sysroot` used from 186G to
# 252G at once, and `stat` reports allocated blocks exactly equal to apparent
# size. Sizing is relative to FREE space on the backing filesystem at creation
# time (homework-luks.c calculate_initial_image_size uses statfs f_bavail), so
# it self-scales and cannot over-commit.
#
# Why deliberately small rather than generous -- the two directions are not
# symmetric, and the gap is three orders of magnitude. Both measured on adora:
#
#   grow   84G -> 150G   1 second     (metadata + allocation)
#   shrink 109G -> 84G   659 seconds  (btrfs block-group relocation)
#
# So guessing low costs a one-second `homectl resize` later, while guessing
# high costs both wasted disk and an 11-minute operation to undo. 35% also
# leaves room for the OS side: bootc deployments, system flatpaks and root
# container storage measured ~101 GB on a well-used krytis machine. For
# reference, the first operator to size this by hand chose 150G against 74.7G
# in use -- roughly 2x actual usage, well under half of free space.
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
        --auto-resize-mode=off --rebalance-weight=off --disk-size=35% \
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
