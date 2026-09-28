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
# 4 in the lookup order). This element installs a small OVERLAY one tier
# higher (/etc/xdg/umbriel/config.toml, tier 2 -- $XDG_CONFIG_DIRS) that
# `[include]`s that file and then sets only the two krytis-specific values.
#
# It used to install a full 836-line copy instead, on the reasoning that
# "config lookup is first-match, not merged across tiers, so a partial
# override would silently drop every other upstream default". The first half
# is true and the conclusion does not follow: tier selection and `[include]`
# merging are two different mechanisms. Once a tier is selected, that file's
# `[include]` list is expanded and deep-merged before any field is read
# (src/config/config_merge.cpp), so a tier-2 file can pull tier 3 in
# explicitly. The full copy froze at upstream's 2026-09-10 schema while
# desktop/umbriel.bst kept tracking refs/heads/main daily, and six settings
# were silently invalid by 2026-09-16 -- see krytis#980 and the rationale in
# files/umbriel/config.toml's header.
#
# `mise run umbriel-config-validate` is the gate that keeps this honest: it
# runs upstream's own `umbriel validate` against the installed
# /etc/xdg/umbriel/config.toml inside the built image.

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
