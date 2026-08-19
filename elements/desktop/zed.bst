kind: manual

# Zed: GPU-accelerated multiplayer code editor (https://zed.dev).
# Pre-built binary release — upstream publishes x86_64 and aarch64 tarballs.
# Installed to /usr/lib/zed/ to preserve RPATH ($ORIGIN/../lib) structure;
# /usr/bin/zed symlinks there. glibc ≥ 2.35 required; fdsdk 25.08 ships 2.42.
# Update path: mise run zed-update / track-zed CI job.
# Closes #237.

build-depends:
- freedesktop-sdk.bst:public-stacks/runtime-minimal.bst

depends:
- freedesktop-sdk.bst:public-stacks/runtime-minimal.bst

variables:
  version: "1.15.1"
  strip-binaries: ''

config:
  strip-commands:
  - ':'

  install-commands:
  - |
    install -d "%{install-root}/usr/lib/zed"
    cp -a bin libexec lib "%{install-root}/usr/lib/zed/"
    install -d "%{install-root}/usr/bin"
    ln -s /usr/lib/zed/bin/zed "%{install-root}/usr/bin/zed"
    cp -a share "%{install-root}/usr/"

sources:
- kind: tar
  (?):
  - arch == "x86_64":
      url: github_files:zed-industries/zed/releases/download/v1.15.1/zed-linux-x86_64.tar.gz
      ref: b9a8a080e707487111436665270a0c961b21a06b86f194375a0c940067cb1a17
  - arch == "aarch64":
      url: github_files:zed-industries/zed/releases/download/v1.15.1/zed-linux-aarch64.tar.gz
      ref: bd6186135cd7f909c8b487e89f2da1d0be0e0c8cebd3be36a707b9823194749a
