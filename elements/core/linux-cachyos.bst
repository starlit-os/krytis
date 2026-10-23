kind: manual

sources:
- kind: remote
  # cachyos_v3 falls back to archive.cachyos.org once this build is superseded
  # (include/aliases.yml `mirrors:`).
  url: cachyos_v3:linux-cachyos-%{version}-%{pkgrel}-x86_64_v3.pkg.tar.zst
  ref: 6f5834a767d9f20d15f4965d7f2c7f11212598f8a13231200d6f099bcd6c1463

variables:
  version: "7.2.11"
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
