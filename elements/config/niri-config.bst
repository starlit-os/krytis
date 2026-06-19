kind: manual

# Ships /etc/niri/config.kdl — the system-wide niri config fallback.
# niri config lookup order: $XDG_CONFIG_HOME/niri/config.kdl → /etc/niri/config.kdl.
# Source: upstream v26.04 default-config.kdl with ghostty substituted for alacritty.

depends:
- freedesktop-sdk.bst:public-stacks/runtime-minimal.bst

variables:
  strip-binaries: ''

config:
  strip-commands:
  - ':'
  install-commands:
  - |
    install -Dm644 config.kdl \
      "%{install-root}%{sysconfdir}/niri/config.kdl"
  - '%{install-extra}'

sources:
- kind: local
  path: files/niri
