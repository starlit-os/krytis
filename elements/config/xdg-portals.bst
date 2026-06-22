kind: manual

build-depends:
- freedesktop-sdk.bst:public-stacks/runtime-minimal.bst

variables:
  strip-binaries: ""

config:
  strip-commands:
  - ":"
  install-commands:
  - |
    install -Dm644 /dev/stdin \
      "%{install-root}%{datadir}/xdg-desktop-portal/portals/niri.portal" <<'EOF'
    [preferred]
    default=gnome;gtk
    org.freedesktop.impl.portal.Settings=gnome
    org.freedesktop.impl.portal.Wallpaper=gnome
    org.freedesktop.impl.portal.Screenshot=gnome
    EOF
  - "%{install-extra}"
