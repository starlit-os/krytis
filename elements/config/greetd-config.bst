# greetd-config — PAM config, greetd.toml, sysusers, and tmpfiles for the
# noctalia-greeter + greetd + cage login stack.
# Installs config only; binaries come from greetd.bst, cage.bst,
# wlr-randr.bst, noctalia-greeter.bst.
#
# greetd.service ships Alias=display-manager.service — installing greetd
# automatically creates the display-manager symlink; no masking needed.
#
# WLR_RENDERER=pixman: wlroots' GLES2 renderer fails on real AMD hardware
# because EGL cannot find the radeonsi DRI driver through glvnd when the
# compositor has a real render node (amdgpu/renderD128). simpledrm worked
# previously because it has no render node, so wlroots auto-selected pixman.
# Force pixman explicitly so the greeter works on both simpledrm and amdgpu.
# WLR_NO_HARDWARE_CURSORS=1: required when pixman renderer is active — the
# pixman path has no KMS cursor plane support.
#
# IMPORTANT: these must be set in greetd config.toml's command line, NOT via
# a systemd drop-in Environment=. greetd constructs a clean PAM environment
# for the greeter child session and does not propagate its own systemd service
# environment to child processes. env(1) in the command line is the only
# reliable path to reach noctalia-greeter-compositor.
#
# Track hardware-accelerated greeter rendering in #95 (parent: #94).
#
# This is a config-only element with no binaries to strip. The default
# buildsystem-make strip-commands call freedesktop-sdk-stripper, which is
# not in runtime-minimal. Override strip-commands with a no-op.
kind: manual

build-depends:
- freedesktop-sdk.bst:public-stacks/runtime-minimal.bst

depends:
- desktop/greetd.bst
- desktop/noctalia-greeter.bst
- desktop/cage.bst
- desktop/wlr-randr.bst

variables:
  strip-binaries: ''

config:
  strip-commands:
  - ':'

  install-commands:
  - |
    install -Dm644 /dev/stdin \
      "%{install-root}%{sysconfdir}/pam.d/greetd" <<'EOF'
    #%PAM-1.0
    # Self-contained: fdsdk does not ship system-local-login or system-auth at
    # runtime (factory copies are stripped in image.bst). Use modules directly.

    auth       required     pam_nologin.so
    auth       required     pam_unix.so
    auth       optional     pam_gnome_keyring.so

    account    required     pam_nologin.so
    account    required     pam_unix.so

    password   required     pam_unix.so sha512 shadow
    -password  optional     pam_gnome_keyring.so use_authtok

    session    required     pam_loginuid.so
    session    optional     pam_keyinit.so force revoke
    session    required     pam_limits.so
    session    required     pam_unix.so
    -session   optional     pam_systemd.so
    session    required     pam_env.so
    session    optional     pam_gnome_keyring.so auto_start
    EOF

  - |
    install -Dm644 /dev/stdin \
      "%{install-root}%{sysconfdir}/greetd/config.toml" <<'EOF'
    [terminal]
    vt = 1

    [default_session]
    command = "env WLR_RENDERER=pixman WLR_NO_HARDWARE_CURSORS=1 noctalia-greeter-session"
    user = "greeter"
    EOF

  - |
    install -Dm644 /dev/stdin \
      "%{install-root}%{indep-libdir}/sysusers.d/greetd.conf" <<'EOF'
    u greeter - "greetd greeter user" /var/lib/greetd -
    m greeter video
    m greeter render
    EOF

  - |
    install -Dm644 /dev/stdin \
      "%{install-root}%{indep-libdir}/tmpfiles.d/noctalia-greeter.conf" <<'EOF'
    d /var/lib/greetd 0750 greeter greeter -
    d /var/lib/noctalia-greeter 0755 greeter greeter -
    EOF

  - "%{install-extra}"
