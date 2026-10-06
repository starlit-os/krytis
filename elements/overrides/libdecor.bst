kind: meson

# freedesktop-sdk's components/libdecor.bst, mirrored without its GTK3 plugin
# (#1075, step 5a of docs/plans/2026-09-30-gtk3-realistic-floor.md). Wired in
# through elements/freedesktop-sdk.bst `overrides:`.
#
# The delta, and nothing else:
#   - `components/gtk3.bst` removed from depends. Disabling the option alone
#     would stop *linking* GTK3 but keep it in the runtime closure.
#   - `-Dgtk=disabled`. The option is `auto` and auto features are enabled in
#     fdsdk, so upstream builds libdecor-gtk.so. libdecor-cairo.so, the fallback
#     plugin, still ships, so client-side decorations keep working.
#
# Unlike plymouth (#1035), libdecor is not on the boot path: its consumers are
# SDL3, sdl2-compat, ffmpeg and gstreamer-libav.
#
# Everything else is copied verbatim from freedesktop-sdk at the junction ref,
# with sibling paths re-namespaced (`freedesktop-sdk.bst:`). The project-scope
# variables are pinned to freedesktop-sdk's values below, because a mirror
# resolves them in krytis's project.conf (see
# docs/skills/bst.md § Default-`auto` meson features are *on* in both junctions).
#
# Update path: tied to the freedesktop-sdk junction ref; deliberately NOT in the
# track-bst-sources.yml matrix. Drift and exit condition are checked by
# `mise run gtk3-mirror-check`. Delete this element and its overrides entry when
# upstream disables gtk or drops the gtk3 dependency (the check fails with
# "delete this mirror").

build-depends:
- freedesktop-sdk.bst:public-stacks/buildsystem-meson.bst
- freedesktop-sdk.bst:components/wayland-protocols.bst

depends:
- freedesktop-sdk.bst:components/cairo.bst
- freedesktop-sdk.bst:components/pango.bst
- freedesktop-sdk.bst:components/wayland.bst

variables:
  # freedesktop-sdk's project-scope values (its include/_private/meson-conf.yml
  # and install-dirs), pinned because this element resolves them in krytis's
  # project scope. LTOJOBS is fdsdk's own nocache environment entry; without it
  # `-Db_lto_threads=${LTOJOBS}` expands empty. Verified by diffing
  # `mise run bst -- show --deps none --format '%{vars}'` and `'%{env}'` of the
  # upstream element against this mirror before wiring the override.
  meson-global: >-
    --buildtype=plain
    -Dauto_features=enabled
    -Db_pie=true
    -Ddefault_library=shared
    -Db_lto=true
    -Db_lto_threads=${LTOJOBS}
  project_licensedir: "%{licensedir}/freedesktop-sdk"
  meson-local: >-
    -Ddemo=false
    -Ddbus=disabled
    -Dgtk=disabled

environment:
  LTOJOBS: "%{max-jobs}"

environment-nocache:
- LTOJOBS

public:
  bst:
    split-rules:
      devel:
        (>):
        - '%{libdir}/libdecor-0.so'

sources:
- kind: git_repo
  url: freedesktop:libdecor/libdecor.git
  track: '*.*.*'
  ref: 0.2.5-0-g149c6f0b05663aaa69fdf7f94be2483776d1a311
