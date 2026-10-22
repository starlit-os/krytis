kind: manual

# `mise tailscale:setup`: the user's opt-in to Tailscale (#1384).
#
# core/tailscale.bst ships tailscaled disabled. This task runs a root-only
# helper through sudo that enables it and makes the calling user its operator,
# then signs in as that user. Kept out of core/tailscale.bst so the tracked
# element only ever changes through tailscale-update's url:/ref: edits.
#
# Files (files/tailscale/):
# - krytis-tailscale-authorize -> /usr/libexec/. Port of dakota's
#   dakota-tailscale-authorize: the user comes from SUDO_UID, read/check/set
#   runs under a lock, and an operator that belongs to someone else is never
#   replaced. No sudoers carve-out: the normal wheel rule (password or FIDO2)
#   is the authorization.
# - setup -> /etc/mise/tasks/tailscale/setup, declared in
#   /etc/mise/conf.d/tailscale.toml. mise does not scan /etc/mise/tasks
#   itself (docs/skills/bst.md § System-wide mise tasks via BST element), and
#   /etc/mise/config.toml belongs to config/fido2-tasks.bst.
#
# The GUI flow (polkit action, pkexec, GTK app) is #1385.

depends:
- freedesktop-sdk.bst:public-stacks/runtime-gnu.bst
- core/mise.bst
- core/tailscale.bst
- freedesktop-sdk.bst:components/python3.bst

variables:
  strip-binaries: ''

config:
  strip-commands:
  - ':'

  install-commands:
  - |
    install -Dm755 krytis-tailscale-authorize \
      "%{install-root}%{prefix}/libexec/krytis-tailscale-authorize"
    install -Dm755 setup "%{install-root}%{sysconfdir}/mise/tasks/tailscale/setup"
    install -Dm644 tailscale.toml "%{install-root}%{sysconfdir}/mise/conf.d/tailscale.toml"
  - '%{install-extra}'

sources:
- kind: local
  path: files/tailscale
