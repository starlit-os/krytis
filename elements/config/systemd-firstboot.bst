# systemd-firstboot.bst: krytis's first-boot setup flow -- keymap, timezone,
# and the initial systemd-homed-managed admin account, prompted on a reserved
# VT (tty5) by krytis-firstboot.service.
#
# systemd's own systemd-firstboot.service / systemd-homed-firstboot.service are
# neutralised rather than reused: their Before=sysinit.target /
# Before=systemd-user-sessions.service hangs an unanswered boot, and that cannot
# be undone from a drop-in, because systemd's dependency directives are purely
# additive there. See the drop-ins in files/systemd-firstboot/ and
# docs/skills/bootc-vm.md § Dependency directives cannot be reset from a drop-in.
#
# Full rationale: docs/design/first-boot-setup.md
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
    install -Dm755 firstboot-wizard.sh \
        "%{install-root}/usr/libexec/krytis/firstboot-wizard.sh"

    install -Dm644 krytis-firstboot.service \
        "%{install-root}%{indep-libdir}/systemd/system/krytis-firstboot.service"

    install -Dm644 systemd-firstboot.service.d/10-krytis.conf \
        "%{install-root}%{indep-libdir}/systemd/system/systemd-firstboot.service.d/10-krytis.conf"
    install -Dm644 systemd-homed-firstboot.service.d/10-krytis.conf \
        "%{install-root}%{indep-libdir}/systemd/system/systemd-homed-firstboot.service.d/10-krytis.conf"

    install -Dm644 /dev/stdin \
        "%{install-root}%{indep-libdir}/systemd/system-preset/72-krytis-firstboot.preset" <<'EOF'
    enable krytis-firstboot.service
    # Restated explicitly even though freedesktop-sdk's own unprefixed
    # systemd-homed-firstboot.preset already disables it: this unit must never be
    # pulled onto the boot path. Preset resolution takes the first matching
    # filename in sort order and digits sort before letters, so this file wins.
    disable systemd-homed-firstboot.service
    EOF
  - "%{install-extra}"

sources:
- kind: local
  path: files/systemd-firstboot
