kind: manual

# Wires pam_u2f into the PAM stacks used by sudo and sshd.
#
# Service → PAM file used:
#   sudo  → system-auth  (fdsdk sudo.bst: "auth include system-auth")
#   sshd  → password-auth
#   greetd login → /etc/pam.d/greetd (managed by config/greetd-config.bst)
#
# Per-user mode (no authfile=): pam_u2f reads ~/.config/Yubico/u2f_keys.
# If that file is absent, pam_u2f returns PAM_USER_UNKNOWN and falls through
# to pam_unix — safe on fresh installs with no key enrolled.
# Users enroll keys without root via: mise fido2:enroll
#
# system-auth and password-auth content pinned to fdsdk linux-pam 1.7.2.
# Reverify base content on junction bumps.
# Note: image.bst strips /usr/share/factory/etc/pam.d/* only;
# actual /etc/pam.d/{system-auth,password-auth} survive in the deployed image.

build-depends:
- freedesktop-sdk.bst:public-stacks/runtime-minimal.bst

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
    install -Dm644 /dev/stdin \
      "%{install-root}%{sysconfdir}/pam.d/system-auth" <<'EOF'
    auth        required      pam_env.so
    -auth       sufficient    pam_systemd_home.so
    auth        sufficient    pam_u2f.so cue
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
    install -Dm644 /dev/stdin \
      "%{install-root}%{sysconfdir}/pam.d/password-auth" <<'EOF'
    auth        required      pam_env.so
    -auth       sufficient    pam_systemd_home.so
    auth        sufficient    pam_u2f.so cue
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
