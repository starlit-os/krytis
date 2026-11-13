kind: manual

sources:
- kind: remote
  # cachyos_v3 falls back to archive.cachyos.org once this build is superseded
  # (include/aliases.yml `mirrors:`).
  url: cachyos_v3:linux-cachyos-%{version}-%{pkgrel}-x86_64_v3.pkg.tar.zst
  ref: 7b11f3f486a3a59bb2606aef16a6243c8fe2a4a3f200aaffaac4505602906113

variables:
  version: "7.3.4"
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
