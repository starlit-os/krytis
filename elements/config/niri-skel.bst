kind: manual

# Seeds /etc/skel/.config/niri/ — copied into new accounts' home dirs by
# useradd --create-home and by homectl firstboot's --skel default (both
# default to /etc/skel; confirmed SKEL=/etc/skel in the shipped
# /etc/default/useradd, from freedesktop-sdk.bst:vm/config/useradd-ostree.bst).
# Same source files as config/niri-config.bst, which keeps shipping
# /etc/niri/ as a secondary system-wide fallback for any account-creation
# path that bypasses skel copy — no content is duplicated, both elements
# read from files/niri/.
#
# Fixes #490: noctalia's theme.templates niri integration
# (assets/templates/niri/apply.sh in noctalia-dev/noctalia, active when
# theme.templates.builtin_ids contains "niri") writes
# ~/.config/niri/noctalia.kdl and, if ~/.config/niri/config.kdl does not
# already exist, creates it containing ONLY `include "noctalia.kdl"`. Once
# that stub exists, niri's own config lookup
# ($XDG_CONFIG_HOME/niri/config.kdl -> /etc/niri/config.kdl) never reaches
# the /etc fallback again for that user, silently discarding every other
# file krytis ships (input.kdl, layout.kdl, rules.kdl, startup.kdl,
# binds.kdl -- all keybinds, the GTK_IM_MODULE compose-key fix, window
# rules). Seeding a real config.kdl here means noctalia's template hits
# its "already exists" branch instead, which only *appends* the include
# line -- additive, not destructive.

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
      install -Dm644 "$f" "%{install-root}%{sysconfdir}/skel/.config/niri/$f"
    done
    for f in binds/*.kdl; do
      install -Dm644 "$f" "%{install-root}%{sysconfdir}/skel/.config/niri/$f"
    done
  - '%{install-extra}'

sources:
- kind: local
  path: files/niri
