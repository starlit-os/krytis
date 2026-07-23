kind: manual

sources:
- kind: remote
  url: cachyos:repo/x86_64_v3/cachyos-v3/linux-cachyos-%{version}-%{pkgrel}-x86_64_v3.pkg.tar.zst
  ref: 2021b891e3d31425a2335cdb5e5b709038fe0c24a0e25d86ccc29e67ccc01265

variables:
  version: "7.1.4"
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
