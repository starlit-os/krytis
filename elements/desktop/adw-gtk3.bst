kind: meson

# GTK3 theme matching libadwaita/GTK4 styling, so GTK3 apps look consistent
# alongside GTK4/libadwaita apps. Not vendored by freedesktop-sdk or
# gnome-build-meta — small standalone upstream project.
build-depends:
- freedesktop-sdk.bst:public-stacks/buildsystem-meson.bst
- deps/sass-shim.bst

depends:
- freedesktop-sdk.bst:public-stacks/runtime-minimal.bst

sources:
- kind: git_repo
  url: github:lassekongo83/adw-gtk3.git
  track: refs/tags/*
  ref: v6.5-0-g34a69db97369475e931b10ce699d0be2307a5def
