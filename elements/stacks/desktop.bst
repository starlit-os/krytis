kind: stack

# Desktop session stack.
# Provides: niri compositor + XDG portal backends + gnome-keyring (Secret portal).
# Plug into oci/krytis/stack.bst alongside base-system and bootc.
depends:
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
