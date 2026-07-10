kind: manual

# Static images added under noctalia's own assets/images dir (alongside
# upstream's assets/images/distros/*.svg). /usr/share is read-only at
# runtime in bootc, so these are baked in at build time — same pattern as
# noctalia-skel.bst, but for shared static assets rather than per-user skel
# state.

depends:
- freedesktop-sdk.bst:public-stacks/runtime-minimal.bst

variables:
  strip-binaries: ''

config:
  strip-commands:
  - ':'
  install-commands:
  - |
    install -Dm644 images/etheria.png \
      "%{install-root}%{datadir}/noctalia/assets/images/etheria.png"

sources:
- kind: local
  path: files/noctalia-assets
