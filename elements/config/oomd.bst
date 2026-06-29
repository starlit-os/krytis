# systemd-oomd — proactive OOM prevention before the kernel OOM killer fires.
# systemd-oomd is compiled into our systemd build; this element enables the service
# and drops a tuning fragment. Closes #219.
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
      "%{install-root}%{indep-libdir}/systemd/oomd.conf.d/krytis.conf" <<'EOF'
    [OOMPolicy]
    SwapUsedLimit=90%
    DefaultMemoryPressureLimit=60%
    DefaultMemoryPressureDurationSec=20s
    EOF

  - |
    install -Dm644 /dev/stdin \
      "%{install-root}%{indep-libdir}/systemd/system-preset/70-krytis-oomd.preset" <<'EOF'
    enable systemd-oomd.service
    EOF
