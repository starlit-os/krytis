# On real hardware systemd-boot does NOT auto-enroll loader/keys/auto by default
# (secure-boot-enroll defaults to if-safe: VMs only). This first-boot oneshot sets
# secure-boot-enroll manual so the user gets a boot-menu prompt to select the key
# set instead of a silent no-op. bootc never writes this setting itself - confirmed
# absent from bootc's source, see docs/skills/secure-boot.md. Closes #309.
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
    install -Dm644 /dev/stdin \
      "%{install-root}%{indep-libdir}/systemd/system/secure-boot-enroll.service" <<'EOF'
    [Unit]
    Description=Set secure-boot-enroll=manual in the ESP's loader.conf
    ConditionFirstBoot=yes
    ConditionPathExists=/boot/loader/loader.conf

    [Service]
    Type=oneshot
    ExecStart=/usr/bin/sh -c 'grep -q "^secure-boot-enroll" /boot/loader/loader.conf || echo "secure-boot-enroll manual" >> /boot/loader/loader.conf'
    RemainAfterExit=yes

    [Install]
    WantedBy=multi-user.target
    EOF

  - |
    install -Dm644 /dev/stdin \
      "%{install-root}%{indep-libdir}/systemd/system-preset/71-krytis-secure-boot-enroll.preset" <<'EOF'
    enable secure-boot-enroll.service
    EOF

  - "%{install-extra}"
