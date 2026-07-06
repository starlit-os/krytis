kind: manual

# Ships /etc/niri/{config.kdl,*.kdl,binds/*.kdl} — the system-wide niri config fallback.
# niri config lookup order: $XDG_CONFIG_HOME/niri/config.kdl → /etc/niri/config.kdl.
# Source: kitten-lily's personal dotfiles (~/.dotfiles/.config/niri), minus output.kdl
# and its include (monitor layout is machine-specific, not shipped in the image).
# niri resolves `include` paths relative to the including file's own directory, so the
# binds/*.kdl includes in binds.kdl still resolve once staged under /etc/niri/binds/.

depends:
- freedesktop-sdk.bst:public-stacks/runtime-minimal.bst

variables:
  strip-binaries: ''

config:
  strip-commands:
  - ':'
  install-commands:
  - |
    for f in config.kdl input.kdl layout.kdl noctalia.kdl rules.kdl startup.kdl binds.kdl; do
      install -Dm644 "$f" "%{install-root}%{sysconfdir}/niri/$f"
    done
    for f in binds/*.kdl; do
      install -Dm644 "$f" "%{install-root}%{sysconfdir}/niri/$f"
    done
  - '%{install-extra}'

sources:
- kind: local
  path: files/niri
