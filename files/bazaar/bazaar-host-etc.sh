#!/bin/bash
# Give the Bazaar flatpak read-only access to the host /etc, so it can read
# /etc/bazaar/{bazaar,curated,blocklist}.yaml. Closes #245.
#
# Bazaar's config path is fixed at compile time by the Flathub build
# (-Dhardcoded_main_config_path=/run/host/etc/bazaar/bazaar.yaml), and that
# build grants no access to it. Without this override /run/host/etc does not
# exist inside the sandbox, and Bazaar silently shows no Curated tab:
#
#   $ flatpak run --command=sh io.github.kolunmi.Bazaar -c 'ls /run/host/etc'
#   ls: cannot access '/run/host/etc': No such file or directory
#
# Bluefin and Aurora ship this permission as a tmpfiles.d `L` symlink from
# /var/lib/flatpak/overrides/<appid> to a file under /usr/share. That doesn't
# port: /usr is read-only here, so the symlink would make the override file
# unwritable and any later `flatpak override --system io.github.kolunmi.Bazaar`
# would fail with EROFS. `flatpak override` merges into the keyfile and leaves
# it mutable, the same as flatpak-cursor-path.sh does for the global override.
#
# `:ro` rather than plain host-etc, because Bazaar only reads. With `:ro`,
# `touch /run/host/etc/probe` inside the sandbox fails "Read-only file system".
#
# Not marker-gated, unlike flatpak-preinstall.sh: the override lives in /var,
# so a `bootc` rollback or a wiped /var must be able to restore it, and the
# operation is local, offline and sub-second. Idempotent: re-running rewrites
# the same key. No ordering against flatpak-preinstall.service is needed,
# because `flatpak override` succeeds for an app that isn't installed yet.
set -euo pipefail

flatpak override --system --filesystem=host-etc:ro io.github.kolunmi.Bazaar
