kind: manual

# /etc/xdg/xdg-desktop-portal/<desktop>-portals.conf: krytis's changes to
# the portal routing niri and xdg-desktop-portal-umbriel ship upstream.
#
# xdp falls through config files per interface
# (xdp-portal-config.c::xdp_portal_config_find, 1.22.1): an interface with no
# key here, and no default= here, resolves from the upstream file in
# /usr/share.
#
# niri-portals.conf is a pure delta: keys only, no default=. Secret →
# oo7-portal (krytis#1028), and none for the four interfaces xdp-gnome
# can't serve under niri (krytis#1054).
#
# umbriel-portals.conf is not a delta. Its default=umbriel;gnome;gtk shadows
# upstream's default=umbriel;gtk for every interface those backends
# implement, so Umbriel gets xdp-gnome (Settings, FileChooser, …) plus pins:
# Access and Notification on gtk, none for what needs gnome-shell, Secret →
# oo7-portal (krytis#1029).
#
# /etc/xdg rather than %{datadir}: the upstream files already own
# /usr/share/xdg-desktop-portal/<desktop>-portals.conf, and XDG_CONFIG_DIRS
# is the system-wide config tier, still overridable per user in ~/.config
# (same reasoning as config/xdg-terminals-list.bst).
#
# mise run portal-routing-check asserts the resolved routing. It fails on a
# key whose removal changes nothing, and on an Umbriel none pin once
# umbriel.portal declares that interface (drop the key then). It can't see
# niri growing a service, so the niri pins are a manual check on niri bumps.
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
