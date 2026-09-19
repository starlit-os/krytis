kind: manual

sources:
- kind: remote
  url: cachyos:repo/x86_64_v3/cachyos-v3/linux-cachyos-%{version}-%{pkgrel}-x86_64_v3.pkg.tar.zst
  ref: af4e86cf75d52a5486f8354fb87d762874e13a02122ef11650e2dac59a729085

variables:
  version: "7.2.6"
  pkgrel: "1"
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
