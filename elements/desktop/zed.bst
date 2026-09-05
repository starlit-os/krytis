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
  version: "1.18.1"
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
      url: github_files:zed-industries/zed/releases/download/v1.18.1/zed-linux-x86_64.tar.gz
      ref: eea62268d8ec5fd3587df06fa76e072c104cca5e0b0b0abecbc28ae5b87c0bad
  - arch == "aarch64":
      url: github_files:zed-industries/zed/releases/download/v1.18.1/zed-linux-aarch64.tar.gz
      ref: 7ee93bcd1059c4f0d700578ccfa00aebda5fc521c943fe3ffbf71aac41a081a7
