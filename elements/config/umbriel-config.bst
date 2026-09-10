kind: manual

# Ships /etc/xdg/umbriel/config.toml -- the system-wide Umbriel config,
# parallel to config/niri-config.bst's /etc/niri/config.kdl role. NOT a reuse
# of that element: Umbriel uses TOML, not KDL, and its config lookup order
# is entirely different (see PACKAGING.md's "Configuration lookup" section
# and files/umbriel/config.toml's header comment).
#
# Unlike niri (which ships no usable default binds/config of its own),
# Umbriel's own examples/config.toml is a complete, Noctalia-integrated
# default -- installed automatically by desktop/umbriel.bst's own meson
# install to the datadir fallback (/usr/share/umbriel/config.toml, tier 3 of
# 4 in the lookup order). This element installs the SAME content one tier
# higher (/etc/xdg/umbriel/config.toml, tier 2 -- $XDG_CONFIG_DIRS), with the
# two krytis-specific edits documented in files/umbriel/config.toml's header.
# Config lookup is first-match, not merged across tiers, so shipping only a
# partial override here would silently drop every other upstream default
# (blur, shadows, animations, window rules, ...) rather than layering on
# top of them -- the full file must be duplicated, not diffed.

depends:
- freedesktop-sdk.bst:public-stacks/runtime-gnu.bst

variables:
  strip-binaries: ''

config:
  strip-commands:
  - ':'
  install-commands:
  - |
    install -Dm644 config.toml "%{install-root}%{sysconfdir}/xdg/umbriel/config.toml"
  - '%{install-extra}'

sources:
- kind: local
  path: files/umbriel
