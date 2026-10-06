kind: meson

# gnome-build-meta's core/gnome-desktop.bst, mirrored without its GTK3 library
# (#1074, step 4 of docs/plans/2026-09-30-gtk3-realistic-floor.md). Wired in
# through elements/gnome-build-meta.bst `overrides:`.
#
# The delta, and nothing else:
#   - `sdk/gtk+-3.bst` removed from depends. Disabling the option alone would
#     stop *linking* GTK3 but keep it in the runtime closure.
#   - `-Dlegacy_library=false`. That option builds libgnome-desktop-3, the GTK3
#     variant. Nothing in the image links it except gnome-desktop's own debug
#     tests (/usr/libexec/gnome-desktop-debug/test-*). xdg-desktop-portal-gnome,
#     the FileChooser backend under niri, links libgnome-desktop-4, which stays.
#
# Everything else is copied verbatim from gnome-build-meta at the junction ref,
# including the qrcodegen subproject source and the `meson subprojects
# packagefiles --apply` configure step. Sibling paths are re-namespaced and
# gnome-build-meta's build plumbing (`include/gcc-for-recc.yml`,
# `buildsystems/meson.bst`) is replaced by fdsdk's buildsystem-meson stack, as in
# desktop/gnome-disk-utility.bst. The project-scope variables are pinned to
# gnome-build-meta's values below, because a mirror resolves them in krytis's
# project.conf (see
# docs/skills/bst.md § Default-`auto` meson features are *on* in both junctions).
#
# Update path: tied to the gnome-build-meta junction ref; deliberately NOT in the
# track-bst-sources.yml matrix. Drift and exit condition are checked by
# `mise run gtk3-mirror-check`. Delete this element and its overrides entry when
# upstream sets legacy_library=false or drops the gtk+-3 dependency (the check
# fails with "delete this mirror").

build-depends:
- freedesktop-sdk.bst:public-stacks/buildsystem-meson.bst
- gnome-build-meta.bst:sdk/gobject-introspection.bst
- gnome-build-meta.bst:sdk/gtk-doc.bst
- freedesktop-sdk.bst:components/itstool.bst

depends:
- gnome-build-meta.bst:sdk/gdk-pixbuf.bst
- gnome-build-meta.bst:sdk/glib.bst
- gnome-build-meta.bst:sdk/gsettings-desktop-schemas.bst
- gnome-build-meta.bst:sdk/gtk.bst
- freedesktop-sdk.bst:components/iso-codes.bst
- freedesktop-sdk.bst:components/libgudev.bst
- freedesktop-sdk.bst:components/libseccomp.bst
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
    -Dgtk_doc=true
    -Dinstalled_tests=true
    -Dlegacy_library=false

config:
  configure-commands:
    (<):
    - meson subprojects packagefiles --apply

sources:
- kind: tar
  url: gnome_downloads:gnome-desktop/51/gnome-desktop-51.0.tar.xz
  ref: 9ebeb9f1769d3c310caeadd921ab34c8f264b92937740518b3bc859a579a6912
- kind: git_repo
  directory: subprojects/qrcodegen
  url: github:nayuki/QR-Code-generator.git
  ref: 8329a7108fc22be3e1eec0a9f9318978579e3621
