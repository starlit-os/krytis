kind: manual

# Proton Pass desktop application (https://proton.me/pass).
# x86_64-only pre-built Electron app; no arm64 release from Proton.
# Bundled Electron — no system electron dependency.
# Update path: mise run proton-pass-update / track-proton-pass CI job.
# Closes #206.

build-depends:
- freedesktop-sdk.bst:components/binutils.bst
- freedesktop-sdk.bst:components/tar.bst

depends:
- freedesktop-sdk.bst:public-stacks/runtime-minimal.bst

variables:
  version: "1.39.1"
  strip-binaries: ''

config:
  strip-commands:
  - ':'

  build-commands:
  - ar x proton-pass.deb data.tar.xz
  - tar -xJf data.tar.xz

  install-commands:
  - cp -a usr "%{install-root}/"
  - "%{install-extra}"

sources:
- kind: remote
  filename: proton-pass.deb
  url: proton_me:download/pass/linux/proton-pass_1.39.1_amd64.deb
  ref: dc3b6de8c1bc90deeaeddaabe287ff46821fd1f6e5f611451355c769da6c5be0
