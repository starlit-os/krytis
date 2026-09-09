kind: manual

# Wires pam_u2f into the PAM stacks used by sudo, the greeter and sshd.
#
# Service → PAM file used:
#   sudo  → system-auth  (fdsdk sudo.bst: "auth include system-auth")
#   sshd  → password-auth
#   greetd login → /etc/pam.d/greetd (managed by config/greetd-config.bst)
#
# password-auth's *auth* block is dormant for sshd as shipped: since #410,
# config/ssh-auth-policy.bst sets KbdInteractiveAuthentication no (alongside
# PasswordAuthentication no), and pam_u2f only runs in the keyboard-interactive
# path — so sshd authenticates over pubkey and never enters this auth stack.
# The account/password/session blocks still run under UsePAM yes, and the auth
# block becomes live again for anyone who overrides that drop-in. Keep it
# correct; do not treat it as dead code. Native sk-* keys are the intended SSH
# second factor. See docs/skills/pam.md § UsePAM yes.
#
# Per-user mode (no authfile=): pam_u2f resolves the authfile from the passwd
# entry's pw_dir as <home>/.config/Yubico/u2f_keys and open()s it during the
# auth phase. Absent → PAM_AUTHINFO_UNAVAIL, so pam_u2f falls through to
# pam_unix — safe on fresh installs with no key enrolled.
# Users enroll keys without root via: mise fido2:enroll
#
# systemd-homed users: the home area is still an unmounted encrypted image
# during login, so pam_u2f's per-user authfile is unreachable and it can
# never serve homed *login* either way — it fails closed
# (PAM_AUTHINFO_UNAVAIL, device presence checked before any prompt) and
# falls through regardless of stack position. That is what makes putting
# pam_u2f *first* safe: for login it is a no-op (home not mounted yet),
# for sudo/polkit it now actually gets a chance (home is mounted by
# then).
#
# pam_u2f used to sit *after* pam_systemd_home (#411's ordering, matching
# where upstream's pam_systemd_home(8) EXAMPLE places its own jump line).
# That was wrong for sudo/polkit: pam_systemd_home always succeeds for a
# homed user via password (no homed FIDO2 login credential exists
# post-#759/#532), and `success=done` ends the whole auth phase
# immediately — pam_u2f, one line below, never ran. The key being
# enrolled and the home being mounted were both irrelevant; sudo always
# fell straight to a password prompt with no FIDO2 attempt at all.
# Reordered in #784: pam_u2f now runs first. FIDO2 for homed *login*
# (unmounted home) still belongs to pam_systemd_home, which still owns
# that credential flow — this reorder only lets pam_u2f actually compete
# for sudo/polkit, where it could not before.
#
# The pam_systemd_home jump spec is upstream's (pam_systemd_home(8) EXAMPLE),
# not `sufficient`: the module returns PAM_USER_UNKNOWN — not PAM_IGNORE —
# for classic /etc/passwd users, so `default=ignore` is what lets them fall
# through, while genuine homed auth failures stay fatal instead of being
# silently retried against pam_unix.
#
# system-auth and password-auth content pinned to fdsdk linux-pam 1.7.2.
# Reverify base content on junction bumps.
# Note: image.bst strips /usr/share/factory/etc/pam.d/* only;
# actual /etc/pam.d/{system-auth,password-auth} survive in the deployed image.

build-depends:
- freedesktop-sdk.bst:public-stacks/runtime-gnu.bst

depends:
- core/pam-u2f.bst

public:
  bst:
    overlap-whitelist:
    - /etc/pam.d/system-auth
    - /etc/pam.d/password-auth

variables:
  strip-binaries: ''

config:
  strip-commands:
  - ':'

  install-commands:
  - |
    install -Dm644 /dev/null \
      "%{install-root}%{sysconfdir}/pam.d/system-auth"
    cat > "%{install-root}%{sysconfdir}/pam.d/system-auth" <<'EOF'
    auth        required      pam_env.so
    auth        sufficient    pam_u2f.so cue pinverification
    -auth       [success=done authtok_err=bad perm_denied=bad maxtries=bad default=ignore] pam_systemd_home.so
    auth        sufficient    pam_unix.so try_first_pass nullok_secure
    auth        required      pam_deny.so

    -account    sufficient    pam_systemd_home.so
    account     required      pam_unix.so

    -password   sufficient    pam_systemd_home.so
    password    requisite     pam_pwquality.so try_first_pass local_users_only retry=3 authtok_type=
    password    sufficient    pam_unix.so try_first_pass use_authtok nullok_secure sha512 shadow
    password    required      pam_deny.so

    -session    optional      pam_systemd_home.so
    session     optional      pam_keyinit.so revoke
    session     required      pam_limits.so
    -session     optional      pam_systemd.so
    session     [success=1 default=ignore] pam_succeed_if.so service in crond quiet use_uid
    session     required      pam_unix.so
    EOF

  - |
    install -Dm644 /dev/null \
      "%{install-root}%{sysconfdir}/pam.d/password-auth"
    cat > "%{install-root}%{sysconfdir}/pam.d/password-auth" <<'EOF'
    auth        required      pam_env.so
    auth        sufficient    pam_u2f.so cue pinverification
    -auth       [success=done authtok_err=bad perm_denied=bad maxtries=bad default=ignore] pam_systemd_home.so
    auth        sufficient    pam_unix.so try_first_pass nullok_secure
    auth        required      pam_deny.so

    -account    sufficient    pam_systemd_home.so
    account     required      pam_unix.so

    -password   sufficient    pam_systemd_home.so
    password    requisite     pam_pwquality.so try_first_pass local_users_only retry=3 authtok_type=
    password    sufficient    pam_unix.so try_first_pass use_authtok nullok_secure sha512 shadow
    password    required      pam_deny.so

    -session    optional      pam_systemd_home.so
    session     optional      pam_keyinit.so revoke
    session     required      pam_limits.so
    -session     optional      pam_systemd.so
    session     [success=1 default=ignore] pam_succeed_if.so service in crond quiet use_uid
    session     required      pam_unix.so
    EOF

  - "%{install-extra}"
