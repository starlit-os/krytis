# starlit-update: silently updates bootc, system Flatpak apps, firmware,
# and mise-managed tools in the background on a daily timer. Anything that
# needs a reboot to take effect (bootc, some fwupd firmware) applies on the
# user's next natural reboot — no auto-reboot logic here. Closes #173.
#
# Gated on ConditionACPower= (native) plus a busctl check-conditions.sh
# script for power-profile and metered-network state. NetworkManager and
# UPower/power-profiles-daemon are already present transitively on this
# image — see docs/skills/bst.md § NetworkManager Is Present and Running.
kind: manual

build-depends:
- freedesktop-sdk.bst:public-stacks/runtime-minimal.bst

variables:
  strip-binaries: ''

config:
  strip-commands:
  - ':'

  install-commands:
  - |
    install -Dm755 check-conditions.sh \
      "%{install-root}/usr/libexec/starlit-update/check-conditions.sh"

    install -Dm644 starlit-update.service \
      "%{install-root}%{indep-libdir}/systemd/system/starlit-update.service"
    install -Dm644 starlit-update.timer \
      "%{install-root}%{indep-libdir}/systemd/system/starlit-update.timer"
    install -Dm644 starlit-update-user.service \
      "%{install-root}%{indep-libdir}/systemd/user/starlit-update-user.service"
    install -Dm644 starlit-update-user.timer \
      "%{install-root}%{indep-libdir}/systemd/user/starlit-update-user.timer"

    install -Dm644 /dev/stdin \
      "%{install-root}%{indep-libdir}/systemd/system-preset/71-krytis-starlit-update.preset" <<'EOF'
    enable starlit-update.timer
    EOF

    install -Dm644 /dev/stdin \
      "%{install-root}%{indep-libdir}/systemd/user-preset/71-krytis-starlit-update.preset" <<'EOF'
    enable starlit-update-user.timer
    EOF

sources:
- kind: local
  path: files/starlit-update
