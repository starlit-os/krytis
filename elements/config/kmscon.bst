# Enables kmscon on VT2-4 only, via preset — never the bare kmsconvt@
# template. The bare template's [Install] section carries
# `DefaultInstance=tty1` and `Alias=autovt@.service`, which would make
# systemd-logind spawn it in place of tty1's getty — greetd owns VT1 and
# must not be preempted this way. Enabling only the tty2/tty3/tty4
# instances keeps each unit's `Conflicts=getty@%i.service` scoped to that
# VT, leaving VT1 to greetd.

kind: manual

build-depends:
- freedesktop-sdk.bst:public-stacks/runtime-minimal.bst

depends:
- desktop/kmscon.bst

variables:
  strip-binaries: ''

config:
  strip-commands:
  - ':'
  install-commands:
  - |
    install -Dm644 /dev/stdin \
      "%{install-root}%{indep-libdir}/systemd/system-preset/80-kmscon.preset" <<'EOF'
    enable kmsconvt@tty2.service
    enable kmsconvt@tty3.service
    enable kmsconvt@tty4.service
    EOF
  - '%{install-extra}'
