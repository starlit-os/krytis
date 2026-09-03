kind: manual

# Zed: GPU-accelerated multiplayer code editor (https://zed.dev).
# Pre-built binary release — upstream publishes x86_64 and aarch64 tarballs.
# Installed to /usr/lib/zed/ to preserve RPATH ($ORIGIN/../lib) structure;
# /usr/bin/zed symlinks there. glibc ≥ 2.35 required; fdsdk 26.08beta.3 ships 2.44.
# Update path: mise run zed-update / track-zed CI job.
# Closes #237.

build-depends:
- freedesktop-sdk.bst:public-stacks/runtime-gnu.bst

depends:
- freedesktop-sdk.bst:public-stacks/runtime-gnu.bst

variables:
  version: "1.18.0"
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
      url: github_files:zed-industries/zed/releases/download/v1.18.0/zed-linux-x86_64.tar.gz
      ref: 60ee2da27b378c5d00cbfc4e9e0c9842e37795803c4565754f41be5423898799
  - arch == "aarch64":
      url: github_files:zed-industries/zed/releases/download/v1.18.0/zed-linux-aarch64.tar.gz
      ref: 1e966d0258d0d96c06dd9216f6e1df223c535b6c5e39c7562912bda8481f63c1
