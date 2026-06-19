kind: manual

depends:
- freedesktop-sdk.bst:public-stacks/runtime-minimal.bst

variables:
  strip-binaries: ''

config:
  install-commands:
  - |
    install -Dm 644 \
        -t "%{install-root}%{indep-libdir}/systemd/system-preset" \
        80-systemd-firstboot.preset
  - "%{install-extra}"

sources:
- kind: local
  path: files/systemd-firstboot
