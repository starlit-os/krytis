kind: manual

# Ships FIDO2 enrollment and status scripts to /etc/mise/tasks/fido2/ so they
# are available system-wide as `mise fido2:*` on the deployed image.
# /etc/mise/config.toml must exist for mise to discover system tasks at all;
# it is installed alongside the scripts.

depends:
- freedesktop-sdk.bst:public-stacks/runtime-minimal.bst
- core/mise.bst

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
