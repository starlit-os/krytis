kind: manual

# Ships FIDO2 enrollment and status scripts to /etc/mise/tasks/fido2/ so they
# are available system-wide as `mise fido2:*` on the deployed image.
# /etc/mise/config.toml must exist for mise to discover system tasks at all;
# it is installed alongside the scripts.
#
# Runtime tools the scripts assume, supplied by stacks/base-system.bst rather
# than declared here (same as cryptsetup/systemd-cryptenroll for enroll-luks):
# fido2-token and pamu2fcfg (libfido2, core/pam-u2f.bst), jq, and homectl
# (systemd) for the systemd-homed enrollment path.

depends:
- freedesktop-sdk.bst:public-stacks/runtime-gnu.bst
- core/mise.bst
- core/gum.bst

variables:
  strip-binaries: ''

config:
  strip-commands:
  - ':'

  install-commands:
  - |
    for script in enroll enroll-luks status test-sudo; do
      install -Dm755 "fido2/${script}" \
        "%{install-root}%{sysconfdir}/mise/tasks/fido2/${script}"
    done
    install -Dm644 config.toml \
      "%{install-root}%{sysconfdir}/mise/config.toml"
  - '%{install-extra}'

sources:
- kind: local
  path: files/fido2-tasks
