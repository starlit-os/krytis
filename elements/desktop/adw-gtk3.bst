kind: manual

# GTK3 theme matching libadwaita/GTK4 styling, so GTK3 apps look consistent
# alongside GTK4/libadwaita apps. Not vendored by freedesktop-sdk or
# gnome-build-meta — small standalone upstream project.
#
# Installed from upstream's own prebuilt release tarball, NOT built from
# source. adw-gtk3's SCSS is written entirely with Dart Sass's module system
# (`@use ... with (...)`, `@forward` — no `@import` anywhere). Neither
# freedesktop-sdk nor gnome-build-meta vendor Dart Sass, so building from
# source here meant bridging to `sassc` (libsass) via a `find_program('sass')`
# shim. libsass never implemented `@use`/`@forward` — the upstream tracker
# closed the feature request as permanently declined
# (github.com/sass/libsass#2807: "LibSass is now deprecated and we aren't
# expecting to add any additional features to it"). `sassc` doesn't hard-fail
# on `@use`; it silently mis-parses it, corrupting the compiled
# gtk-3.0/gtk-dark.css enough that GTK3's own CSS parser then rejected chunks
# of it (`Theme parsing error: gtk-dark.css:N:0: unknown @ rule`) and the
# theme's own `.background:backdrop` rule (unfocused-window background) was
# among the casualties.
#
# Upstream's own release CI builds with a real Dart Sass toolchain and
# attaches the compiled `gtk-3.0`/`gtk-4.0` theme directories as a release
# asset tarball — installing that directly sidesteps the incompatibility
# entirely, at the cost of `bst source track` no-op'ing on `kind: tar` (see
# `mise/tasks/tarball-update`'s TARGETS table for the update path).
#
# GTK3 is deprecated for krytis long-term; this element is expected to be
# dropped entirely once nothing in the image still depends on a GTK3 theme.
depends:
- freedesktop-sdk.bst:public-stacks/runtime-gnu.bst

variables:
  strip-binaries: ""

config:
  strip-commands:
  - ":"
  install-commands:
  - |
    mkdir -p "%{install-root}%{datadir}/themes"
    cp -a adw-gtk3 adw-gtk3-dark "%{install-root}%{datadir}/themes/"
  - "%{install-extra}"

sources:
- kind: tar
  url: github_files:lassekongo83/adw-gtk3/releases/download/v6.5/adw-gtk3v6.5.tar.xz
  base-dir: ""
  ref: a81780fadfc432be0fc3d89c4ebb41aa28e4f032d42c36f9789c57dd10cfa41c
