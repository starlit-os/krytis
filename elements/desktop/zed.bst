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
  version: "1.13.2"
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
      url: github_files:zed-industries/zed/releases/download/v1.13.2/zed-linux-x86_64.tar.gz
      ref: 44508886bed247c7544f64b66e06bd388ec3d406776b5457868bc14a67130724
  - arch == "aarch64":
      url: github_files:zed-industries/zed/releases/download/v1.13.2/zed-linux-aarch64.tar.gz
      ref: 708bf3642a86c1ac7367764b9b4bb32fc3c9bc18aafdf3b50e2b401f7df108db
