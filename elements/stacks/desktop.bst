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

  # ── User accounts ──────────────────────────────────────────────────────
  # accounts-daemon: AccountsService D-Bus daemon. noctalia-greeter queries
  # org.freedesktop.Accounts for user avatar paths (IconFile property).
  # Without it the greeter falls back to the generic person glyph. D-Bus
  # activated — no systemd preset needed. Closes #182.
  - gnome-build-meta.bst:core-deps/accountsservice.bst

  # ── Files ───────────────────────────────────────────────────────────────
  - gnome-build-meta.bst:core/nautilus.bst
  # gvfs-daemon: GIO volume monitor runtime plugins via D-Bus. Without it Nautilus
  # has no volume monitor (gvfs-udisks2-volume-monitor) so non-boot disks do not
  # appear in the sidebar, and trash:// and network mounts (SMB/NFS/SFTP) are broken.
  # gvfs-daemon depends on udisks2, so this covers both. Closes #157.
  - gnome-build-meta.bst:core/gvfs-daemon.bst

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

  # ── Icons ──────────────────────────────────────────────────────────────
  # Papirus: flat icon theme providing Papirus, Papirus-Dark, and Papirus-Light
  # variants. Closes #208.
  - desktop/papirus-icon-theme.bst
  # adw-gtk3: GTK3 theme matching libadwaita/GTK4 styling, so GTK3 apps
  # look consistent alongside GTK4/libadwaita apps.
  - desktop/adw-gtk3.bst
  # gtk-settings: sets Papirus as the system-wide GTK icon theme and
  # adw-gtk3-dark as the system-wide GTK theme via /etc/gtk-3.0/settings.ini
  # and dconf.
  - config/gtk-settings.bst

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
  # xdg-terminal-exec: XDG terminal execution spec — allows apps and the desktop
  # to open a terminal without hardcoding a specific emulator. Closes #171.
  - desktop/xdg-terminal-exec.bst

  # ── Monitor control ────────────────────────────────────────────────────
  # ddcutil: reads and writes monitor settings (brightness, contrast, colour
  # temperature) via DDC/CI over I2C. Includes i2c-tools for bus access.
  # Closes #177.
  - desktop/ddcutil.bst

  # ── Boot splash ────────────────────────────────────────────────────────
  # plymouth: graphical boot splash between firmware hand-off and greetd.
  # plymouth-quit.service depends on display-manager.service; greetd ships
  # Alias=display-manager.service so the quit ordering is automatic.
  # kargs (quiet splash) are baked via config/bootc.bst kargs.d. Closes #100.
  - freedesktop-sdk.bst:components/plymouth.bst
  # plymouth-theme: pins Theme=spinner + krytis watermark (no firmware logo).
  - config/plymouth-theme.bst

  # ── Input devices ──────────────────────────────────────────────────────
  # steam-devices: Valve gaming controllers (Steam Controller, Index, Deck,
  # DualShock 4/5, Xbox, etc.) — udev rules granting user access.
  - freedesktop-sdk.bst:components/steam-devices.bst
  # game-devices-udev: broader set — Sony, Microsoft, Nintendo, 8BitDo, Razer,
  # HTC (Vive), Logitech, Thrustmaster, VKB, and others. Coexists with
  # steam-devices (no rule overlap). Closes #186.
  - desktop/game-devices-udev.bst

  # ── System performance tuning ──────────────────────────────────────────
  # IO schedulers, audio PM, SATA link power, THP, amdgpu modprobe, ntsync,
  # amd-pstate EPP hint. Ported from CachyOS-Settings.
  - config/desktop-udev.bst
  # power-profiles-daemon: D-Bus API for balanced/performance/power-saver switching.
  # Works standalone (no GNOME required). Required by falcond (#221). Closes #218.
  - gnome-build-meta.bst:core-deps/power-profiles-daemon.bst
  # falcond: PikaOS gaming performance daemon — per-game profiles, SCX scheduler
  # selection (scx_lavd/bpfland), AMD 3D VCache management, DMEM GPU memory protection.
  # Supersedes gamemode as a single daemon; scx_loader is a hard runtime dependency,
  # not superseded (falcond is purely a D-Bus client of org.scx.Loader, no scheduler
  # code of its own). Requires PPD at runtime. Do NOT run alongside gamemode. Closes #221.
  - desktop/falcond.bst
  # scx_loader: D-Bus on-demand loader of sched-ext CPU schedulers.
  # Provides org.scx.Loader on the system bus; required by falcond (#221)
  # for per-game scheduler switching. Requires kernel sched-ext support
  # (present in linux-cachyos). Closes #228.
  - desktop/scx-loader.bst

  # ── Apps ───────────────────────────────────────────────────────────────
  # All pre-built desktop apps are grouped in desktop-apps to keep this file
  # focused on session infrastructure. Add new apps to stacks/desktop-apps.bst.
  - stacks/desktop-apps.bst

  # ── Config ─────────────────────────────────────────────────────────────
  - config/niri-config.bst
  - config/noctalia-skel.bst
  - config/noctalia-assets.bst

  # ── Flatpak pre-install ─────────────────────────────────────────────────
  # Installs initial system Flatpak apps (Bazaar app store, …) on
  # first boot. Retries if the network was unavailable; marker file at
  # /var/lib/flatpak/.krytis-preinstall-done gates re-execution.
  # The bootc-installer flatpak (org.bootcinstaller.Installer) is never
  # added to the OCI image — it only lives in the live ISO overlay — so no
  # removal service is needed. Closes #66; resolves #175 installer concern.
  - config/flatpak-preinstall.bst

  # ── Background updates ──────────────────────────────────────────────────
  # Silently updates bootc, system Flatpak, firmware, and mise tools on a
  # daily timer. Placed here (not base-system) because it covers system
  # Flatpak, which only exists once the desktop stack is present. Closes #173.
  - config/starlit-update.bst
