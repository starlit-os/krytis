kind: manual

sources:
- kind: remote
  url: cachyos:repo/x86_64_v3/cachyos-v3/linux-cachyos-%{version}-%{pkgrel}-x86_64_v3.pkg.tar.zst
  ref: ce323cf8721198a5d2774fb64dc09106bf6ae600ffb3ad7fa5d9ac69be546b02

variables:
  version: "7.2.8"
  pkgrel: "2"
  strip-binaries: ""

build-depends:
- freedesktop-sdk.bst:components/tar.bst
- freedesktop-sdk.bst:components/zstd.bst

depends:
- freedesktop-sdk.bst:public-stacks/runtime-gnu.bst

config:
  # .pkg.tar.zst is a flat tar archive — extract then install usr/ only
  # (ignoring pacman metadata files: .BUILDINFO, .MTREE, .PKGINFO)
  build-commands:
  - tar --zstd -xf *.pkg.tar.zst

  install-commands:
  - cp -a usr "%{install-root}/"
  - "%{install-extra}"
