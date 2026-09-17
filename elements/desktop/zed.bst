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
  version: "1.20.2"
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
      url: github_files:zed-industries/zed/releases/download/v1.20.2/zed-linux-x86_64.tar.gz
      ref: 647dc85e09fcd99cd175365a89b7b70ccf96469c4844eb8ae6eb83dfa82f7600
  - arch == "aarch64":
      url: github_files:zed-industries/zed/releases/download/v1.20.2/zed-linux-aarch64.tar.gz
      ref: 715a5252234522bc9e8e4a8c1f9b462cf7bb2881eed23b7c8ae650b41c24aa6f
