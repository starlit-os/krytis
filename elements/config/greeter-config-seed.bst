# greeter-config-seed: seeds /var/lib/noctalia-greeter/greeter.toml with
# hide_logo = true on first boot, replacing the old no-brand-logo.patch
# dropped in the git_repo switch to upstream v1.0.0 (which added the
# appearance.hide_logo option natively).
#
# /var is writable runtime state in the bootc composefs layout — bootc flags
# non-dir files baked into the OCI layer's /var, so the config cannot be
# shipped there directly. tmpfiles.d is not a fit either: `w` won't create
# the file on first boot and `f` truncates on every boot, clobbering the
# user's saved greeter preferences. A ConditionPathExists-gated oneshot unit
# (same pattern as flatpak-preinstall.bst) seeds once and leaves the mutable
# file alone. The tmpfiles.d `d` line for /var/lib/noctalia-greeter comes from
# upstream noctalia-greeter itself (v1.1.0+) and creates the directory this
# unit writes into.
# Closes #296.
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
    install -Dm644 greeter.toml \
      "%{install-root}%{datadir}/noctalia-greeter/greeter.toml"

    install -Dm755 greeter-config-seed.sh \
      "%{install-root}/usr/libexec/krytis/greeter-config-seed.sh"

    install -Dm644 greeter-config-seed.service \
      "%{install-root}%{indep-libdir}/systemd/system/greeter-config-seed.service"

    install -Dm644 /dev/stdin \
      "%{install-root}%{indep-libdir}/systemd/system-preset/72-krytis-greeter-config-seed.preset" <<'EOF'
    enable greeter-config-seed.service
    EOF

sources:
- kind: local
  path: files/greeter-config-seed
