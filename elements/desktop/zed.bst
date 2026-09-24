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
  version: "1.21.0"
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
      url: github_files:zed-industries/zed/releases/download/v1.21.0/zed-linux-x86_64.tar.gz
      ref: b79a992e960ed4067cb2b50d66789ed8618eeb1780ed6a0f8f1e71dd80f74200
  - arch == "aarch64":
      url: github_files:zed-industries/zed/releases/download/v1.21.0/zed-linux-aarch64.tar.gz
      ref: 69eff51b22203be7a4d0fd9df0864a8abd4d5183e8fb9aafa2af57f3cd42b9a3
