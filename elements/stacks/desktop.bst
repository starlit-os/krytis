kind: stack

# Desktop session stack.
# Provides: niri compositor + greetd login manager + noctalia shell + XDG portals + gnome-keyring.
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

  # ── Shell ───────────────────────────────────────────────────────────────
  - desktop/noctalia.bst

  # ── Terminal ────────────────────────────────────────────────────────────
  - desktop/ghostty.bst

  # ── XDG portals ────────────────────────────────────────────────────────
  # xdg-desktop-portal (base daemon) is pulled in transitively.
  - gnome-build-meta.bst:core-deps/xdg-desktop-portal-gtk.bst
  - gnome-build-meta.bst:core-deps/xdg-desktop-portal-gnome.bst
  # niri.portal: routes portal interface requests to gnome/gtk backends
  # when XDG_CURRENT_DESKTOP=niri; without this file xdg-desktop-portal
  # cannot resolve the correct backend and default app lookups fail.
  - config/xdg-portals.bst

  # ── Credentials ────────────────────────────────────────────────────────
  - gnome-build-meta.bst:core/gnome-keyring.bst

  # ── Files ───────────────────────────────────────────────────────────────
  - gnome-build-meta.bst:core/nautilus.bst

  # ── Flatpak ────────────────────────────────────────────────────────────
  # flatpak binary is already present transitively via xdg-desktop-portal.
  # This adds the Flathub remote to /usr/share/flatpak/remotes.d/ so it is
  # available system-wide without a post-boot manual setup step.
  - gnome-build-meta.bst:gnomeos-deps/flathub-config.bst

  # ── X11 compatibility ──────────────────────────────────────────────────
  # xwayland.bst: Xwayland server binary.
  # xwayland-satellite: rootless XWayland manager for Niri — starts XWayland
  # on demand when an X11 client connects and sets DISPLAY in the session.
  # config/xwayland-satellite.bst: corrected service file + preset (gnome-build-meta
  # cargo kind only installs the binary, not the upstream resources/ service file).
  - freedesktop-sdk.bst:components/xwayland.bst
  - gnome-build-meta.bst:sdk/xwayland-satellite.bst
  - config/xwayland-satellite.bst

  # ── Vulkan ICD discovery ────────────────────────────────────────────────
  # fdsdk mesa installs ICDs under /usr/lib/.../GL/vulkan/icd.d/ which the
  # Vulkan loader does not search. compat-vulkan-link symlinks that path to
  # /usr/share/vulkan/icd.d/ so radv/lvp/etc. are discoverable. Required by
  # Zink (OpenGL-over-Vulkan) and any direct Vulkan app. Closes #94 partial.
  - freedesktop-sdk.bst:components/compat-vulkan-link.bst

  # ── Fonts ──────────────────────────────────────────────────────────────
  # Symbols Nerd Font: symbols-only variant providing icon glyphs used by
  # terminals (ghostty) and UI components that reference nerd font codepoints.
  - desktop/symbols-nerd-font.bst
  # Noto Color Emoji: color emoji font for broad Unicode emoji coverage.
  - freedesktop-sdk.bst:components/noto-emoji.bst
  # DejaVu: broad Unicode coverage fallback (Dingbats U+2700–U+27BF, geometric
  # shapes, etc.) — fills gaps in MonoLisaCode outside Nerd Font PUA ranges.
  - freedesktop-sdk.bst:components/dejavu-fonts.bst
  # Adwaita fonts: GNOME system UI font.
  - gnome-build-meta.bst:sdk/adwaita-fonts.bst

  # ── Camera ─────────────────────────────────────────────────────────────
  # libcamera: camera abstraction library (UVC, IPU3, etc.).
  # pipewire-daemon: includes spa-0.2/libcamera (built with -Dlibcamera=enabled),
  #   which is the PipeWire libcamera source node; apps access cameras via the
  #   PipeWire/WirePlumber graph and the xdg-desktop-portal camera portal.
  # wireplumber: session/policy manager — required for pipewire-daemon to route
  #   streams between sources (libcamera) and sinks (apps/portal).
  # vm/config/pipewire: installs the user-preset that enables pipewire.socket
  #   and pipewire-pulse.socket on first login.
  # Note: v4l2loopback (virtual V4L2 device kernel module) is out-of-tree and
  #   requires a prebuilt CachyOS package vendor (see issue #86).
  - freedesktop-sdk.bst:components/libcamera.bst
  - freedesktop-sdk.bst:components/pipewire-daemon.bst
  - freedesktop-sdk.bst:components/wireplumber.bst
  - freedesktop-sdk.bst:vm/config/pipewire.bst

  # ── XDG utilities ──────────────────────────────────────────────────────
  # xdg-open: opens URLs/files via xdg-desktop-portal (org.freedesktop.portal.OpenURI).
  # Required for ghostty URL links and any app that calls xdg-open.
  - desktop/xdg-utils.bst

  # ── Config ─────────────────────────────────────────────────────────────
  - config/niri-config.bst
