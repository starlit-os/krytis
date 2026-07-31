# krytis SSH authentication policy — key-only, no passwords.
#
# Delivered as a drop-in rather than a sed against the upstream sshd_config,
# which is only possible because core/openssh.bst now prepends
# `Include /etc/ssh/sshd_config.d/*.conf` (#408). Numbered 10- so krytis policy
# is read before systemd's 20-systemd-userdb.conf; they set disjoint keywords
# today, so the ordering is precautionary rather than load-bearing.
#
# sshd.service ships `disable`d by preset (openssh.preset: "OpenSSH server is
# not requirements for desktop applications"), so this sets the posture for a
# user who opts in with `systemctl enable --now sshd`, not shipped behaviour.
#
# This is a config-only element with no binaries to strip. The default
# buildsystem-make strip-commands call freedesktop-sdk-stripper, which is not in
# runtime-minimal — override strip-commands with a no-op (same as config/oomd.bst).
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
      "%{install-root}%{sysconfdir}/ssh/sshd_config.d/10-krytis-auth.conf" <<'EOF'
    # krytis: SSH authentication is public-key only.
    #
    # BOTH settings are required. Setting PasswordAuthentication alone is the
    # classic incomplete hardening: with `UsePAM yes` (which krytis sets, for
    # pam_u2f and pam_systemd_home), keyboard-interactive hands the challenge to
    # PAM, which prompts for a password anyway. Measured on this image:
    #
    #   PasswordAuthentication no + KbdInteractiveAuthentication yes
    #     -> Authentications that can continue: publickey,keyboard-interactive
    #   both no
    #     -> Authentications that can continue: publickey
    #
    # PermitRootLogin already defaults to prohibit-password upstream; this
    # extends the same posture to every other account.
    #
    # Hardware tokens are unaffected: openssh is built --with-security-key-builtin,
    # so sk-ssh-ed25519@openssh.com and sk-ecdsa-sha2-nistp256@openssh.com
    # authenticate over PUBKEY and need no keyboard-interactive path. Native sk-*
    # keys are the intended SSH second factor here, not pam_u2f.
    #
    # Two accepted consequences, see docs/skills/pam.md:
    #   * Incompatible with homed-managed homes — pam_systemd_home needs the
    #     user's password to unlock the encrypted home, so pubkey-only SSH has
    #     nothing to mount it with. Fine while accounts are created by useradd.
    #   * No PAM-driven 2FA over SSH (pam_u2f). Use sk-* keys.
    #
    # Recovery from lockout is via console — krytis is a desktop, not a headless
    # server. Anyone who needs passwords back can override this file in
    # /etc/ssh/sshd_config.d/ with a lower-numbered drop-in.
    PasswordAuthentication no
    KbdInteractiveAuthentication no
    EOF

  - "%{install-extra}"
