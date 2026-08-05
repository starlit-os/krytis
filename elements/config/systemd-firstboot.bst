# systemd-firstboot.bst: enables and configures krytis's first-boot flow --
# keymap/timezone (systemd-firstboot.service) and the initial
# systemd-homed-managed admin account (systemd-homed-firstboot.service).
# Both units are overridden off the critical boot path (tty2, not
# blocking sysinit/login) -- see docs/design/first-boot-setup.md.
kind: manual

depends:
- freedesktop-sdk.bst:public-stacks/runtime-minimal.bst

variables:
  strip-binaries: ''

config:
  install-commands:
  - |
    install -Dm 644 \
        -t "%{install-root}%{indep-libdir}/systemd/system-preset" \
        80-systemd-firstboot.preset 80-systemd-homed-firstboot.preset
  - |
    install -Dm 644 \
        systemd-firstboot.service.d/10-krytis.conf \
        "%{install-root}%{indep-libdir}/systemd/system/systemd-firstboot.service.d/10-krytis.conf"
  - |
    install -Dm 644 \
        systemd-homed-firstboot.service.d/10-krytis.conf \
        "%{install-root}%{indep-libdir}/systemd/system/systemd-homed-firstboot.service.d/10-krytis.conf"
  - "%{install-extra}"

sources:
- kind: local
  path: files/systemd-firstboot
