#!/bin/bash
# Put the host's cursor themes on libXcursor's search path inside every
# Flatpak sandbox. Closes #949.
#
# Flatpak apps DO inherit XCURSOR_THEME from the session (environment.d, and
# niri's own `cursor { }` export). What they cannot do is find the theme:
#
#   /usr/share/icons        in the runtime — `hicolor` only, no cursors
#   ~/.icons                empty
#   ~/.local/share/icons    per-app data dir, `hicolor` only
#   /run/host/share/icons   the host's themes, bind-mounted by flatpak itself
#
# libXcursor searches the first three. The fourth is where Adwaita actually
# is, and it is not on that list, so the lookup fails and every X11 client
# falls back to the built-in core cursor — the black X11 pointer.
#
# environment.d cannot fix this. Flatpak strips XCURSOR_PATH from the
# inherited environment while forwarding XCURSOR_THEME:
#
#   $ XCURSOR_PATH=/usr/share/icons XCURSOR_THEME=Adwaita \
#       flatpak run --command=sh <app> -c 'echo $XCURSOR_PATH / $XCURSOR_THEME'
#   <unset> / Adwaita
#
# So an override is the only mechanism, and `flatpak override` is the only
# safe way to write one: /var/lib/flatpak/overrides/global is mutable and may
# already carry operator entries (filesystems=, other env). Writing the file
# directly — including via a tmpfiles.d `f+` line — truncates whatever else is
# in it. `flatpak override` merges into the keyfile instead.
set -euo pipefail

# Ordered host-first, because the host image is where krytis's themes live;
# the two ~/ entries cover a user-installed theme and are expanded by
# libXcursor itself. Non-existent entries are skipped, so listing all four is
# free.
XCURSOR_PATH='/run/host/share/icons:/run/host/user-share/icons:~/.local/share/icons:~/.icons'

# Idempotent: re-running rewrites the same key to the same value. This is not
# marker-gated like flatpak-preinstall.sh on purpose — the override lives in
# /var, so a `bootc` rollback or a wiped /var must be able to restore it, and
# the operation is local, offline and sub-second.
flatpak override --system --env="XCURSOR_PATH=${XCURSOR_PATH}"
