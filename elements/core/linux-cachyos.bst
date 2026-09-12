kind: manual

sources:
- kind: remote
  url: cachyos:repo/x86_64_v3/cachyos-v3/linux-cachyos-%{version}-%{pkgrel}-x86_64_v3.pkg.tar.zst
  ref: a4a2ffead7d6a36d9d5390e79649cdee57d5aa94361b94e181cc0f18568b3a29

variables:
  version: "7.2.4"
  pkgrel: "3"
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
