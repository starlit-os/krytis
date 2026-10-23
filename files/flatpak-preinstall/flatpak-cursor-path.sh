#!/bin/bash
# krytis's system-wide Flatpak override, applied to every sandbox:
#   - the host's cursor themes on libXcursor's search path (#949)
#   - read-only access to the GTK user CSS noctalia themes (#1400)
#
# The unit and script keep their original cursor-only name: renaming an
# enabled unit would leave a dangling enablement on existing installs, because
# system presets are only applied on first boot.
#
# ── Cursor path (#949) ──────────────────────────────────────────────────────
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
#
# ── GTK theme (#1400) ───────────────────────────────────────────────────────
# noctalia's gtk3/gtk4 templates write ~/.config/gtk-{3,4}.0/noctalia.css and
# add `@import url("noctalia.css");` to gtk.css beside it. A sandboxed GTK app
# reads $XDG_CONFIG_HOME/gtk-4.0/gtk.css, and Flatpak sets $XDG_CONFIG_HOME to
# ~/.var/app/<id>/config, so the app never sees the import and renders stock
# Adwaita. `filesystems=host` doesn't help: it exposes ~/.config but leaves
# $XDG_CONFIG_HOME pointing at the per-app dir.
#
# Granting xdg-config/gtk-{3,4}.0 makes flatpak bind-mount each host directory
# onto the same path under the app's own $XDG_CONFIG_HOME, so the relative
# @import resolves: gtk.css and the noctalia.css it imports sit side by side.
# `:ro` because apps only read the CSS. With it,
# `touch $XDG_CONFIG_HOME/gtk-4.0/probe` inside the sandbox fails "Read-only
# file system". Harmless when a user has the GTK templates off: GTK finds no
# gtk.css, or one without the import.
set -euo pipefail

# Ordered host-first, because the host image is where krytis's themes live;
# the two ~/ entries cover a user-installed theme and are expanded by
# libXcursor itself. Non-existent entries are skipped, so listing all four is
# free.
XCURSOR_PATH='/run/host/share/icons:/run/host/user-share/icons:~/.local/share/icons:~/.icons'

# Idempotent: re-running rewrites the same keys to the same values. This is not
# done once per app like flatpak-preinstall.sh's installs, on purpose — the override lives in
# /var, so a `bootc` rollback or a wiped /var must be able to restore it, and
# the operation is local, offline and sub-second. One flatpak process, so this
# unit stays a single link in the #1371 repo-creation ordering chain.
flatpak override --system \
    --env="XCURSOR_PATH=${XCURSOR_PATH}" \
    --filesystem=xdg-config/gtk-3.0:ro \
    --filesystem=xdg-config/gtk-4.0:ro
