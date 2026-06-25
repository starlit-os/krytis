kind: autotools

build-depends:
- freedesktop-sdk.bst:public-stacks/buildsystem-autotools.bst

depends:
- freedesktop-sdk.bst:public-stacks/runtime-minimal.bst
  # gio / gdbus — used by xdg-open to invoke org.freedesktop.portal.OpenURI
- freedesktop-sdk.bst:components/glib.bst

variables:
  # xdg-utils has no C code — no shared/static libs to configure
  conf-link-args: ""
  # out-of-tree builds not supported by xdg-utils' configure
  build-dir: ""

config:
  # Build only the scripts/ subdir (generates shell scripts from .in templates).
  # Skips html/man targets which require xmlto/xsltproc.
  # install silently skips man pages if absent (if/fi guard in Makefile.in).
  build-commands:
  - make -j1 -C scripts scripts
  install-commands:
  - make -j1 -C scripts DESTDIR="%{install-root}" install

sources:
- kind: git_repo
  url: freedesktop:xdg/xdg-utils.git
  track: v*.*.*
  ref: v1.2.1-0-g356c380ad6fecc9ce6bea1f6a77986ba67402c80
