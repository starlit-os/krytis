kind: manual

# Ships FIDO2 enrollment and status scripts to /etc/mise/tasks/ so they are
# available system-wide via `mise run <task>` on the deployed image.
# /etc/mise/tasks/ is mise's system config root — scripts there are visible to
# all users without any per-user config.

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
    for script in enroll-fido2 enroll-fido2-luks status-u2f test-u2f-sudo; do
      install -Dm755 "${script}" \
        "%{install-root}%{sysconfdir}/mise/tasks/${script}"
    done
  - '%{install-extra}'

sources:
- kind: local
  path: files/fido2-tasks
