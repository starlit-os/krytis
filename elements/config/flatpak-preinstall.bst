# flatpak-preinstall: installs initial system Flatpak apps on first boot.
# The service retries on subsequent boots if the network was unavailable.
# Flatpak binary is already present transitively via xdg-desktop-portal.
# Closes #66.
kind: manual

depends:
- freedesktop-sdk.bst:public-stacks/runtime-minimal.bst

variables:
  strip-binaries: ''

config:
  strip-commands:
  - ':'

  install-commands:
  - |
    install -Dm755 flatpak-preinstall.sh \
      "%{install-root}/usr/libexec/krytis/flatpak-preinstall.sh"

    install -Dm644 flatpak-preinstall.service \
      "%{install-root}%{indep-libdir}/systemd/system/flatpak-preinstall.service"

    install -Dm644 /dev/stdin \
      "%{install-root}%{indep-libdir}/systemd/system-preset/72-krytis-flatpak-preinstall.preset" <<'EOF'
    enable flatpak-preinstall.service
    EOF

sources:
- kind: local
  path: files/flatpak-preinstall
