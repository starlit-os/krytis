kind: manual

sources:
- kind: remote
  url: cachyos:repo/x86_64_v3/cachyos-v3/linux-cachyos-%{version}-%{pkgrel}-x86_64_v3.pkg.tar.zst
  ref: 0ffcb70397feee9acc6f6bce16229e457c8ad92db331ad6d1110cbcd88b6e027

variables:
  version: "7.1.3"
  pkgrel: "1"
  strip-binaries: ""

build-depends:
- freedesktop-sdk.bst:components/tar.bst
- freedesktop-sdk.bst:components/zstd.bst

depends:
- freedesktop-sdk.bst:public-stacks/runtime-minimal.bst

config:
  # .pkg.tar.zst is a flat tar archive — extract then install usr/ only
  # (ignoring pacman metadata files: .BUILDINFO, .MTREE, .PKGINFO)
  build-commands:
  - tar --zstd -xf *.pkg.tar.zst

  install-commands:
  - cp -a usr "%{install-root}/"
  - "%{install-extra}"
