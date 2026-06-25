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
  # generate-help-script.awk reads each script's .txt (produced by xmlto) for
  # the one-line synopsis used in --help output.  Rather than pulling in a full
  # text-browser toolchain (xmlto + docbook-xml + docbook-xsl + lynx), generate
  # minimal stub .txt files before building.  Scripts are fully functional;
  # --help just shows "xdg-<name>" as the synopsis.
  build-commands:
  - |
    cd scripts
    for xml in desc/*.xml; do
      base=$(basename "$xml" .xml)
      printf 'Name\n\n%s\n\nDescription\n' "$base" > "$base.txt"
    done
    make -j1 scripts
  install-commands:
  - make -j1 -C scripts DESTDIR="%{install-root}" install

sources:
- kind: git_repo
  url: freedesktop:xdg/xdg-utils.git
  track: v*.*.*
  ref: v1.2.1-0-g356c380ad6fecc9ce6bea1f6a77986ba67402c80
