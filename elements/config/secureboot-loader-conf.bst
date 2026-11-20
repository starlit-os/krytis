# On real hardware systemd-boot does NOT auto-enroll loader/keys/auto by default
# (secure-boot-enroll defaults to if-safe: VMs only). krytis sets
# secure-boot-enroll manual, so the boot menu offers "Enroll Secure Boot keys: auto"
# instead of a silent no-op on hardware or a silent auto-enroll in a VM. Closes #309.
#
# Two paths put the setting on the ESP:
#
# 1. Install time (#1570). bootc >= 1.17.4 (bootc-dev/bootc cbd34248) copies
#    /usr/lib/bootc/install/systemd-boot/loader.conf from the image onto the ESP as
#    loader/loader.conf right after `bootctl install`, replacing bootctl's template.
#    So the setting is in force on the very first boot. The ISO path gets it as well,
#    because fisherman runs the payload image's own bootc for composefs installs.
#    The file keeps bootctl's two commented template lines, because bootc's copy
#    replaces the template wholesale. With no `timeout` the menu stays hidden, as on
#    every earlier install (bootc 1.17.3's fallback `timeout 5` never ran, because
#    bootctl had always written its template first).
#
# 2. First boot (the oneshot below). This covers machines installed before (1). bootc
#    writes loader.conf only at install time, so they never receive the file from
#    (1). On a new install the line is already present, and the grep makes the
#    oneshot a no-op.
kind: manual

build-depends:
- freedesktop-sdk.bst:public-stacks/runtime-gnu.bst

variables:
  strip-binaries: ''

config:
  strip-commands:
  - ':'

  install-commands:
  - |
    install -Dm644 /dev/null \
      "%{install-root}%{indep-libdir}/systemd/system/secure-boot-enroll.service"
    cat > "%{install-root}%{indep-libdir}/systemd/system/secure-boot-enroll.service" <<'EOF'
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
    install -Dm644 /dev/null \
      "%{install-root}%{indep-libdir}/bootc/install/systemd-boot/loader.conf"
    cat > "%{install-root}%{indep-libdir}/bootc/install/systemd-boot/loader.conf" <<'EOF'
    #timeout 3
    #console-mode keep
    secure-boot-enroll manual
    EOF

  - |
    install -Dm644 /dev/null \
      "%{install-root}%{indep-libdir}/systemd/system-preset/71-krytis-secure-boot-enroll.preset"
    cat > "%{install-root}%{indep-libdir}/systemd/system-preset/71-krytis-secure-boot-enroll.preset" <<'EOF'
    enable secure-boot-enroll.service
    EOF

  - "%{install-extra}"
