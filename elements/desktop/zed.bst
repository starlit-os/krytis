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
  version: "1.15.0"
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
      url: github_files:zed-industries/zed/releases/download/v1.15.0/zed-linux-x86_64.tar.gz
      ref: abf751395da92fcac783e1ec59e9812ac4c4ebb33a27f7f51059edde1aee99f9
  - arch == "aarch64":
      url: github_files:zed-industries/zed/releases/download/v1.15.0/zed-linux-aarch64.tar.gz
      ref: ac73c9491adf06acfe17b322b0d5564e16d96cb0214d3b6a5bc72d67dd351741
