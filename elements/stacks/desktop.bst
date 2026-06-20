kind: stack

# Desktop session stack.
# Provides: niri compositor + greetd login manager + XDG portals + gnome-keyring.
# Plug into oci/krytis/stack.bst alongside base-system and bootc.
depends:
  # ── GPU / Mesa ─────────────────────────────────────────────────────────
  # mesa-default installs /etc/ld.so.conf.d/00_mesa.conf so ldconfig
  # can find libgbm and other mesa libs at GL/default/lib at runtime.
  - freedesktop-sdk.bst:vm/mesa-default.bst

  # ── Login manager ──────────────────────────────────────────────────────
  # greetd + cage + wlr-randr + noctalia-greeter + PAM/config files.
  - config/greetd-config.bst

  # ── Compositor ─────────────────────────────────────────────────────────
  - desktop/niri.bst

  # ── Terminal ────────────────────────────────────────────────────────────
  - desktop/ghostty.bst

  # ── XDG portals ────────────────────────────────────────────────────────
  # xdg-desktop-portal (base daemon) is pulled in transitively.
  - gnome-build-meta.bst:core-deps/xdg-desktop-portal-gtk.bst
  - gnome-build-meta.bst:core-deps/xdg-desktop-portal-gnome.bst

  # ── Credentials ────────────────────────────────────────────────────────
  - gnome-build-meta.bst:core/gnome-keyring.bst

  # ── Config ─────────────────────────────────────────────────────────────
  - config/niri-config.bst
