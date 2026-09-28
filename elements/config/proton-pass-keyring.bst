# proton-pass-keyring: force pass-cli's local encryption key into the Secret
# Service instead of the kernel keyring.
#
# pass-cli keeps its encrypted session on disk (~/.local/share/proton-pass-cli/)
# but stores the key that decrypts it in a system keyring, and its Linux default
# is kernel keyutils — its own log line reads "Linux keyring: using kernel
# keyutils (cleared on reboot)". Data outlives the key across a reboot, so the
# next invocation hits
#
#   Error: Local encryption key not found but local data exists.
#          Forcing logout for security.
#
# and wipes the session: a browser `pass-cli login` every single boot before
# `mise run pull-keys` works again. PROTON_PASS_LINUX_KEYRING=dbus selects the
# zbus Secret Service store instead ("using zbus secret service (persistent)"),
# which on krytis is oo7-daemon writing ~/.local/share/keyrings/v1/login.keyring.
#
# Deliberately unconditional, unlike config/ssh-agent-env.bst's guarded fish
# snippet. A guard that falls back to keyutils when the collection is locked is
# worse than the error it avoids: a single pass-cli run under the *other* backend
# re-encrypts the local state with a key the desktop session cannot read, and the
# next run either force-logs-out again or dies with
# `sqlcipher_page_cipher: hmac check failed` on the settings DB. One backend for
# every context is the property worth having; `PROTON_PASS_LINUX_KEYRING=kernel`
# is still honoured if something genuinely headless needs the old behaviour.
#
# pass-cli itself is NOT in the image (desktop/proton-pass.bst ships the Electron
# GUI, which does not read this variable). It is dev-host tooling installed via
# mise — see mise.toml — so this file is inert until someone installs it.
#
# Two drop-ins because they cover disjoint process trees:
#   - environment.d  -> the systemd user manager, so niri and everything it
#                       spawns (see docs/skills/desktop.md § Variables in
#                       `environment.d/90-krytis-session.conf`).
#   - profile.d      -> login shells that never go through the user manager:
#                       ssh, tty. /etc/profile iterates /etc/profile.d/*.sh.
# A user file of the same name in ~/.config/environment.d/ masks the
# environment.d one, which is how a chezmoi-managed dotfile stays authoritative.
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
      "%{install-root}%{indep-libdir}/environment.d/50-proton-pass-cli.conf"
    cat > "%{install-root}%{indep-libdir}/environment.d/50-proton-pass-cli.conf" <<'EOF'
    # Persist pass-cli's local key in the Secret Service (oo7), not the kernel
    # keyring, which is cleared on reboot. See config/proton-pass-keyring.bst.
    PROTON_PASS_LINUX_KEYRING=dbus
    EOF

  - |
    install -Dm644 /dev/null \
      "%{install-root}%{sysconfdir}/profile.d/50-proton-pass-cli.sh"
    cat > "%{install-root}%{sysconfdir}/profile.d/50-proton-pass-cli.sh" <<'EOF'
    # Covers login shells (ssh, tty) that the systemd user manager never
    # touches, so environment.d cannot reach them. An explicit setting wins:
    # exporting PROTON_PASS_LINUX_KEYRING=kernel stays honoured.
    # `:-` matters: a login shell that runs `set -u` would otherwise abort here
    # on the unset variable, taking the rest of /etc/profile with it.
    [ -n "${PROTON_PASS_LINUX_KEYRING:-}" ] || export PROTON_PASS_LINUX_KEYRING=dbus
    EOF
  - "%{install-extra}"
