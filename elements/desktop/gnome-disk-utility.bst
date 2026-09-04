kind: meson

# GNOME Disks — partition editor, filesystem/LUKS management, SMART reporting
# and disk-image mount/write, on top of the udisks2 daemon krytis already
# ships (gvfs-daemon depends on it — see stacks/desktop.bst).
#
# This is a mirror of gnome-build-meta's elements/core/gnome-disk-utility.bst
# (junction-pinned 46.1) with exactly one behavioural change:
# `-Dgsd_plugin=false`, which drops src/notify/gsd-disk-utility-notify.
#
# Why mirror instead of `- gnome-build-meta.bst:core/gnome-disk-utility.bst`:
# upstream's element carries `depends: core/gnome-settings-daemon.bst` for that
# plug-in, and g-s-d drags nine more elements into the image (colord,
# cups-pk-helper, geocode-glib, gweather-locations, libgweather, ibus-daemon,
# libcanberra, xdg-sound-theme, intltool). Measured with the reverse-dep survey
# in docs/skills/bst.md: 14 elements new to oci/krytis/image.bst's graph via
# the junction element, 7 via this mirror (itself, libcanberra, libdvdread,
# libdvdcss, libhandy, xdg-sound-theme, intltool).
#
# The plug-in cannot run here. Despite the name it is not a g-s-d module: it is
# a standalone binary (libexec/gsd-disk-utility-notify, deps gmodule + gtk3 +
# libnotify + udisks2 only — gnome-disk-utility's meson.build never asks for
# gnome-settings-daemon at all) started by an autostart entry,
# /etc/xdg/autostart/org.gnome.SettingsDaemon.DiskUtilityNotify.desktop, whose
# body is `OnlyShowIn=GNOME;`. krytis does process XDG autostart — niri.service
# carries `Wants=xdg-desktop-autostart.target` — but every session it starts
# sets XDG_CURRENT_DESKTOP=niri (config/greetd-config.bst, files/niri/
# config.kdl), and systemd-xdg-autostart-generator honours OnlyShowIn. So the
# generated unit's condition can never pass: the binary and the .desktop are
# unreachable weight, and g-s-d's whole closure would be dead image content and
# live rows in the SBOM/Grype report.
#
# Note the corollary — g-s-d is not a *build* requirement for the plug-in
# either, so a mirror could keep the plug-in and still drop the dep. It is
# disabled because nothing on krytis can start it, not because it would fail
# to compile. So the cost of bringing SMART notifications back is a starter
# unit, not a dependency closure: #726 tracks whether we want them and by
# which mechanism. Flipping this option means updating
# mise/tasks/gnome-disk-utility-check, which asserts it.
#
# libcanberra is declared here even though upstream's element does not declare
# it: gnome-disk-utility's meson.build asks for `libcanberra-gtk3`
# unconditionally, at top level, *outside* the gsd_plugin block. Upstream gets
# it transitively through gnome-settings-daemon, so dropping g-s-d without
# adding libcanberra fails at `meson setup`. Same reasoning for libnotify.
#
# Update path: deliberately NOT in the track-bst-sources.yml matrix — the
# source ref is tied to the gnome-build-meta junction, not tracked
# independently, and `bst source track` is a no-op on `kind: tar` anyway.
# Drift against the junction is checked by `mise run gnome-disk-utility-check`.
#
# Removal condition: gnome-disk-utility main is being rewritten for GTK4, and
# upstream's element already has a `channel == "nightly"` arm with no
# gnome-settings-daemon dependency. Once that lands in a release and
# gnome-build-meta's stable arm drops `core/gnome-settings-daemon.bst`, delete
# this element plus the check task and put
# `gnome-build-meta.bst:core/gnome-disk-utility.bst` in
# stacks/desktop-apps.bst instead. The check task reports that dep going away.

variables:
  meson-local: >-
    -Dgsd_plugin=false

build-depends:
- freedesktop-sdk.bst:public-stacks/buildsystem-meson.bst
- freedesktop-sdk.bst:components/desktop-file-utils.bst
- freedesktop-sdk.bst:components/docbook-xsl.bst
- freedesktop-sdk.bst:components/libxslt.bst

depends:
- gnome-build-meta.bst:core-deps/libcanberra.bst
- gnome-build-meta.bst:core-deps/libdvdread.bst
- gnome-build-meta.bst:core-deps/libhandy.bst
- gnome-build-meta.bst:core-deps/udisks2.bst
- gnome-build-meta.bst:sdk/adwaita-icon-theme.bst
- gnome-build-meta.bst:sdk/glib.bst
- gnome-build-meta.bst:sdk/gtk+-3.bst
- gnome-build-meta.bst:sdk/libnotify.bst
- gnome-build-meta.bst:sdk/libsecret.bst
- freedesktop-sdk.bst:components/pwquality.bst
- freedesktop-sdk.bst:public-stacks/runtime-minimal.bst

sources:
- kind: tar
  url: gnome_downloads:gnome-disk-utility/46/gnome-disk-utility-46.1.tar.xz
  ref: c24e9439a04d70bcfae349ca134c7005435fe2b6f452114df878bff0b89bbffe
