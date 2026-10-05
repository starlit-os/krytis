kind: manual

# /etc/xdg/xdg-desktop-portal/<desktop>-portals.conf: krytis's changes to
# the portal routing niri and xdg-desktop-portal-umbriel ship upstream.
#
# Each file holds only what krytis changes. xdp falls through config files
# per interface (xdp-portal-config.c::xdp_portal_config_find, 1.22.1): an
# interface with no key here, and no default= here, resolves from the
# upstream file in /usr/share. So a file with one key changes one route.
# Today that key is Secret → oo7-portal in both sessions (krytis#1028).
#
# /etc/xdg rather than %{datadir}: the upstream files already own
# /usr/share/xdg-desktop-portal/<desktop>-portals.conf, and XDG_CONFIG_DIRS
# is the system-wide config tier, still overridable per user in ~/.config
# (same reasoning as config/xdg-terminals-list.bst).
#
# mise run portal-routing-check asserts the resolved routing, and fails when
# an upstream file starts saying what a key here says (delete the key then).
# See docs/skills/desktop.md § xdg-desktop-portal routing.

depends:
- freedesktop-sdk.bst:public-stacks/runtime-gnu.bst

variables:
  strip-binaries: ''

config:
  strip-commands:
  - ':'
  install-commands:
  - |
    for f in *-portals.conf; do
      install -Dm644 "$f" "%{install-root}%{sysconfdir}/xdg/xdg-desktop-portal/$f"
    done
  - '%{install-extra}'

sources:
- kind: local
  path: files/xdg-desktop-portal
