# gaming: Proton/Wine environment defaults for the gaming sysext.
# WOW64, ntsync (kernel module already autoloaded unconditionally by
# config/desktop-udev.bst — not duplicated here), and native Wayland.
# Ported from zirconium-hawaii's files/gamerslop-config/etc/profile.d/gamerslop.sh.
# Sourced by every login shell via /etc/profile.d.
kind: manual

build-depends:
- freedesktop-sdk.bst:public-stacks/runtime-minimal.bst

variables:
  strip-binaries: ''

config:
  install-commands:
  - |
    install -Dm644 /dev/stdin \
      "%{install-root}%{sysconfdir}/profile.d/gaming.sh" <<'EOF'
    export PROTON_ENABLE_WOW64=1
    export PROTON_USE_WOW64=1
    export PROTON_ENABLE_NTSYNC=1
    export PROTON_USE_NTSYNC=1
    export PROTON_ENABLE_WAYLAND=1
    export PROTON_USE_WAYLAND=1
    export PROTON_PREFER_SDL=1
    EOF
