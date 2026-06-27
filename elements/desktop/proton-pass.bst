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
  version: "1.37.0"
  strip-binaries: ''

config:
  strip-commands:
  - ':'

  build-commands:
  - ar x proton-pass.deb data.tar.xz
  - tar -xJf data.tar.xz

  install-commands:
  - cp -a usr/lib/proton-pass "%{install-root}%{indep-libdir}/"
  - |
    install -d "%{install-root}%{bindir}"
    ln -s '%{indep-libdir}/proton-pass/Proton Pass' "%{install-root}%{bindir}/proton-pass"
  - install -Dm644 usr/share/applications/proton-pass.desktop "%{install-root}%{datadir}/applications/proton-pass.desktop"
  - install -Dm644 usr/share/pixmaps/proton-pass.png "%{install-root}%{datadir}/pixmaps/proton-pass.png"
  - "%{install-extra}"

sources:
- kind: remote
  filename: proton-pass.deb
  url: proton_me:download/pass/linux/proton-pass_1.37.0_amd64.deb
  ref: 30b26f1402abeb3d03479e20613830abdb1e6f91e4e616ce7fff52780571076d
