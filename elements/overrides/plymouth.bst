kind: meson

# freedesktop-sdk's components/plymouth.bst, mirrored without its X11 renderer
# (#1035, step 5a of docs/plans/2026-09-30-gtk3-realistic-floor.md). Wired in
# through elements/freedesktop-sdk.bst `overrides:`.
#
# The delta, and nothing else:
#   - `components/gtk3.bst` removed from depends. Disabling the option alone
#     would stop *linking* GTK3 but keep it in the runtime closure.
#   - `-Dgtk=disabled`. The option is `enabled` upstream, and its only product
#     is renderers/x11.so ("if disabled, there is no X11 support"). drm.so and
#     frame-buffer.so, the renderers a boot actually uses, don't link GTK3.
#   - Three depends that upstream only gets through gtk3's runtime closure,
#     declared here because removing gtk3 removes them: meson.build requires
#     xkbcommon and xkeyboard-config unconditionally (the first build without
#     them failed `Dependency "xkbcommon" not found`), and links libudev
#     because the `udev` feature is `auto` (fdsdk enables auto features). The
#     systemd build-dep covers libudev at build time, but nothing else keeps it
#     in plymouth's runtime closure. dbus-1 and curses are needed only with
#     `upstart-monitoring`, which is off.
#
# Breakage Gate: plymouth is on the boot path. config/plymouth-theme.bst
# depends on it, and core/initramfs.bst pulls both in, so dracut bakes this
# build into the initramfs (splash and LUKS passphrase prompt).
#
# files/plymouth/plymouthd.defaults is a verbatim copy of freedesktop-sdk's: a
# `kind: local` source resolves in the project that owns the element, so the
# mirror cannot reach fdsdk's copy. `mise run gtk3-mirror-check` diffs it too.
#
# Everything else is copied verbatim from freedesktop-sdk at the junction ref,
# with sibling paths re-namespaced (`freedesktop-sdk.bst:`). The project-scope
# variables are pinned to freedesktop-sdk's values below, because a mirror
# resolves them in krytis's project.conf (see
# docs/skills/bst.md § Default-`auto` meson features are *on* in both junctions).
#
# Update path: tied to the freedesktop-sdk junction ref; deliberately NOT in the
# track-bst-sources.yml matrix. Drift and exit condition are checked by
# `mise run gtk3-mirror-check`. Delete this element, its overrides entry and
# files/plymouth/plymouthd.defaults when upstream disables gtk or drops the
# gtk3 dependency (the check fails with "delete this mirror").

build-depends:
- freedesktop-sdk.bst:public-stacks/buildsystem-meson.bst
- freedesktop-sdk.bst:components/_private/git-minimal.bst
- freedesktop-sdk.bst:components/docbook-xml.bst
- freedesktop-sdk.bst:components/docbook-xsl.bst
- freedesktop-sdk.bst:components/libxslt.bst
- freedesktop-sdk.bst:components/systemd.bst

depends:
- freedesktop-sdk.bst:public-stacks/runtime-minimal.bst
- freedesktop-sdk.bst:components/libdrm.bst
- freedesktop-sdk.bst:components/libevdev.bst
- freedesktop-sdk.bst:components/pango.bst
- freedesktop-sdk.bst:components/plymouth-logo.bst
# Not in upstream's element; see the header.
- freedesktop-sdk.bst:components/libxkbcommon.bst
- freedesktop-sdk.bst:components/xorg-data-xkeyboard-config.bst
- freedesktop-sdk.bst:components/systemd-libs.bst

variables:
  # freedesktop-sdk's project-scope values (its include/_private/meson-conf.yml
  # and install-dirs), pinned because this element resolves them in krytis's
  # project scope. LTOJOBS is fdsdk's own nocache environment entry; without it
  # `-Db_lto_threads=${LTOJOBS}` expands empty.
  meson-global: >-
    --buildtype=plain
    -Dauto_features=enabled
    -Db_pie=true
    -Ddefault_library=shared
    -Db_lto=true
    -Db_lto_threads=${LTOJOBS}
  project_licensedir: "%{licensedir}/freedesktop-sdk"
  meson-local: >-
    -Dlogo="%{datadir}/pixmaps/freedesktop-sdk-40.png"
    -Dgtk=disabled

environment:
  LTOJOBS: "%{max-jobs}"

environment-nocache:
- LTOJOBS

config:
  install-commands:
    (>):
    - |
      install -Dm644 -t "%{install-root}%{datadir}/plymouth" plymouthd.defaults

sources:
- kind: git_repo
  url: freedesktop:plymouth/plymouth.git
  track: '*.*.*'
  ref: 26.134.222-0-gd15928a8e06c217aad0f2e3579df23fec93dc009
- kind: local
  path: files/plymouth/plymouthd.defaults
