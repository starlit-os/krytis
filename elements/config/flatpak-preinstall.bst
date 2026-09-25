# flatpak-preinstall: installs initial system Flatpak apps on first boot.
# The service retries on subsequent boots if the network was unavailable.
# Flatpak binary is already present transitively via xdg-desktop-portal.
# Closes #66.
#
# Also carries flatpak-cursor-path, a second oneshot that writes a system-wide
# XCURSOR_PATH override so sandboxed X11 apps can find the host's cursor
# themes (#949). Same element because both are "system Flatpak configuration
# applied at boot" and share this files/ directory; different units because
# the preinstall is network-gated and runs once, while the override is local
# and reasserts every boot. See the script header for why an override is the
# only mechanism that works.
kind: manual

depends:
- freedesktop-sdk.bst:public-stacks/runtime-gnu.bst

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

    install -Dm644 /dev/null \
      "%{install-root}%{indep-libdir}/systemd/system-preset/72-krytis-flatpak-preinstall.preset"
    cat > "%{install-root}%{indep-libdir}/systemd/system-preset/72-krytis-flatpak-preinstall.preset" <<'EOF'
    enable flatpak-preinstall.service
    EOF

  - |
    install -Dm755 flatpak-cursor-path.sh \
      "%{install-root}/usr/libexec/krytis/flatpak-cursor-path.sh"

    install -Dm644 flatpak-cursor-path.service \
      "%{install-root}%{indep-libdir}/systemd/system/flatpak-cursor-path.service"

    install -Dm644 /dev/null \
      "%{install-root}%{indep-libdir}/systemd/system-preset/72-krytis-flatpak-cursor-path.preset"
    cat > "%{install-root}%{indep-libdir}/systemd/system-preset/72-krytis-flatpak-cursor-path.preset" <<'EOF'
    enable flatpak-cursor-path.service
    EOF

sources:
- kind: local
  path: files/flatpak-preinstall
