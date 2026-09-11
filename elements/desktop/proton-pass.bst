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
- freedesktop-sdk.bst:public-stacks/runtime-gnu.bst

variables:
  version: "1.40.2"
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
  url: proton_me:download/pass/linux/proton-pass_1.40.2_amd64.deb
  ref: 347a50d5e7edc8aaf2b2a438d5719f01b1c4519ee18daad3c8e201a6c176561a
