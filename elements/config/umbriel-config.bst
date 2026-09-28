kind: manual

# Ships /etc/xdg/umbriel/{config,input,layout,colors,rules,binds}.toml -- the
# system-wide Umbriel config, parallel to config/niri-config.bst's /etc/niri/
# role, and split the same way files/niri/*.kdl is. NOT a reuse of that
# element: Umbriel uses TOML, not KDL, and its config lookup order is entirely
# different (see PACKAGING.md's "Configuration lookup" section and
# files/umbriel/config.toml's header comment).
#
# Unlike niri (which ships no usable default binds/config of its own),
# Umbriel's own examples/config.toml is a complete, Noctalia-integrated
# default -- installed automatically by desktop/umbriel.bst's own meson
# install to the datadir fallback (/usr/share/umbriel/config.toml, tier 3 of
# 4 in the lookup order). This element installs an OVERLAY one tier higher
# (/etc/xdg/umbriel/config.toml, tier 2 -- $XDG_CONFIG_DIRS) that `[include]`s
# that file and then layers the krytis fragments over it.
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
# This element is only half the story: on its own it is bypassed entirely the
# moment a user enables noctalia's Umbriel theme template, which writes a
# tier-1 ~/.config/umbriel/config.toml. config/umbriel-skel.bst seeds the file
# that makes that template additive instead of destructive (krytis#982) -- both
# elements read from files/umbriel/, no content is duplicated.
#
# `mise run umbriel-config-validate` is the gate that keeps this honest: it
# runs upstream's own `umbriel config validate` against the installed
# /etc/xdg/umbriel/config.toml and /etc/skel/.config/umbriel/config.toml inside
# the built image.

depends:
- freedesktop-sdk.bst:public-stacks/runtime-gnu.bst

variables:
  strip-binaries: ''

config:
  strip-commands:
  - ':'
  install-commands:
  - |
    for f in config.toml input.toml layout.toml colors.toml rules.toml binds.toml; do
      install -Dm644 "$f" "%{install-root}%{sysconfdir}/xdg/umbriel/$f"
    done
  - '%{install-extra}'

sources:
- kind: local
  path: files/umbriel
