kind: meson

# gnome-build-meta's sdk/libportal.bst, mirrored without its GTK3 backend (#1074,
# step 4 of docs/plans/2026-09-30-gtk3-realistic-floor.md). Wired in through
# elements/gnome-build-meta.bst `overrides:`, so every consumer (Nautilus,
# xdg-desktop-portal-gnome) gets this build.
#
# The delta, and nothing else:
#   - `sdk/gtk+-3.bst` removed from depends. Disabling the option alone would
#     stop *linking* GTK3 but keep it in the runtime closure.
#   - `-Dbackend-gtk3=disabled`. gnome-build-meta disables only the Qt backends;
#     the GTK3 one is `auto` and auto features are enabled in both junctions, so
#     upstream builds libportal-gtk3, which nothing in the image links.
#
# Everything else is copied verbatim from gnome-build-meta at the junction ref,
# with sibling paths re-namespaced and gnome-build-meta's build plumbing
# (`include/gcc-for-recc.yml`, `buildsystems/meson.bst`) replaced by fdsdk's
# buildsystem-meson stack, as in desktop/gnome-disk-utility.bst. The project-scope
# variables are pinned to gnome-build-meta's values below, because a mirror
# resolves them in krytis's project.conf (see
# docs/skills/bst.md § Default-`auto` meson features are *on* in both junctions).
#
# Update path: tied to the gnome-build-meta junction ref; deliberately NOT in the
# track-bst-sources.yml matrix. Drift and exit condition are checked by
# `mise run gtk3-mirror-check`. Delete this element and its overrides entry when
# upstream disables backend-gtk3 or drops the gtk+-3 dependency (the check fails
# with "delete this mirror").

build-depends:
- freedesktop-sdk.bst:public-stacks/buildsystem-meson.bst
- gnome-build-meta.bst:sdk/gi-docgen.bst
- gnome-build-meta.bst:sdk/gobject-introspection.bst
- gnome-build-meta.bst:sdk/vala.bst

depends:
- gnome-build-meta.bst:sdk/gtk.bst
- freedesktop-sdk.bst:public-stacks/runtime-minimal.bst

variables:
  # gnome-build-meta's project-scope values (its project.conf), pinned because
  # this element resolves them in krytis's project scope. Verified by diffing
  # `mise run bst -- show --deps none --format '%{vars}'` of the upstream
  # element against this mirror before wiring the override.
  meson-global: >-
    --buildtype=plain
    --auto-features=enabled
    --wrap-mode=nodownload
  project_licensedir: "%{licensedir}/gnome"
  meson-local: >-
    -Dbackend-qt5=disabled
    -Dbackend-qt6=disabled
    -Dbackend-gtk3=disabled

sources:
- kind: git_repo
  url: github:flatpak/libportal.git
  track: "*.*.*"
  ref: 0.11.0-0-gfc4d62cfe131e8494c82f597f92b2234d584c367
