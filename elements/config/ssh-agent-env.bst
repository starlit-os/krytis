# ssh-agent-env: vendored fish drop-in pointing SSH_AUTH_SOCK at
# gcr-ssh-agent's socket.
#
# gcr-4 (gnome-build-meta.bst:sdk/gcr.bst, pulled in by desktop/noctalia.bst)
# ships /usr/libexec/gcr-ssh-agent plus gcr-ssh-agent.socket/.service as user
# units, listening on $XDG_RUNTIME_DIR/gcr/ssh. Nothing exported the variable,
# so every shell fell back to no agent at all — oo7 replaced gnome-keyring and
# ships no ssh-agent of its own (docs/design/secrets-service.md).
#
# /usr/share/fish/vendor_conf.d is fish's package-owned config directory:
# auto-loaded for every user, no $XDG_CONFIG_HOME write, and a user file in
# ~/.config/fish/conf.d of the same name shadows it.
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
      "%{install-root}%{datadir}/fish/vendor_conf.d/ssh-agent.fish"
    cat > "%{install-root}%{datadir}/fish/vendor_conf.d/ssh-agent.fish" <<'EOF'
    # Point SSH_AUTH_SOCK at gcr-ssh-agent (gcr-ssh-agent.socket).
    #
    # Guard 1 — SSH_AUTH_SOCK already set: leave it. An inherited value is
    # always more specific than this default: `ssh -A` forwarding, a
    # hand-started ssh-agent, or a deliberate per-shell override.
    #
    # Guard 2 — socket missing: do nothing. The path is socket-activated by
    # the systemd --user manager, so it is absent in a container, on a tty
    # login before the user manager is up, and on any build without gcr-4.
    # Exporting a dead path is worse than exporting nothing: ssh(1) reports
    # "Error connecting to agent" instead of falling through to on-disk keys.
    if not set -q SSH_AUTH_SOCK
        and test -S "$XDG_RUNTIME_DIR/gcr/ssh"
        set -gx SSH_AUTH_SOCK "$XDG_RUNTIME_DIR/gcr/ssh"
    end
    EOF
  - "%{install-extra}"
