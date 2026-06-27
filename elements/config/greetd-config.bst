# greetd-config — PAM config, greetd.toml, sysusers, and tmpfiles for the
# noctalia-greeter + greetd + cage login stack.
# Installs config only; binaries come from greetd.bst, cage.bst,
# wlr-randr.bst, noctalia-greeter.bst.
#
# greetd.service ships Alias=display-manager.service — installing greetd
# automatically creates the display-manager symlink; no masking needed.
#
# WLR_RENDERER=pixman: wlroots Vulkan renderer is compiled in (desktop/wlroots.bst
# uses -Drenderers=vulkan) but CANNOT be used for the greeter compositor:
# it has a DMA-BUF import size limit of 2560x2560 pixels (AMD DCC tiling
# modifier constraint), which blocks 3440x1440 ultrawides. The wlroots Vulkan
# renderer is also explicitly "experimental and not expected to be ready for
# daily use" per its own startup log.
# WLR_NO_HARDWARE_CURSORS=1: required with pixman — no KMS cursor plane support.
# See #96 (parent: #94) for the investigation history.
#
# IMPORTANT: these must be set in greetd config.toml's command line, NOT via
# a systemd drop-in Environment=. greetd constructs a clean PAM environment
# for the greeter child session and does not propagate its own systemd service
# environment to child processes. env(1) in the command line is the only
# reliable path to reach noctalia-greeter-compositor.
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
- core/pam-u2f.bst

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
    # Self-contained: greetd has session-specific auth requirements that differ
    # from system-auth (pam_nologin, gnome-keyring). pam_u2f is inserted before
    # pam_unix so a enrolled FIDO2 key is tried first; absent file falls through.

    auth       required     pam_nologin.so
    auth       sufficient   pam_u2f.so cue pinverification
    auth       required     pam_unix.so
    auth       optional     pam_gnome_keyring.so

    account    required     pam_nologin.so
    account    required     pam_unix.so

    password   required     pam_unix.so sha512 shadow
    -password  optional     pam_gnome_keyring.so use_authtok

    session    required     pam_loginuid.so
    session    optional     pam_keyinit.so force revoke
    session    required     pam_limits.so
    # pam_env must run before pam_systemd so that XDG_SESSION_TYPE=wayland
    # is visible when logind registers the session. Without it, logind sees
    # a tty-type session, denies the seat to libseat, and the compositor hangs.
    session    required     pam_env.so readenv=1
    session    required     pam_unix.so
    -session   optional     pam_systemd.so
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

  - |
    install -Dm644 /dev/stdin \
      "%{install-root}%{sysconfdir}/environment" <<'EOF'
    XDG_SESSION_TYPE=wayland
    XDG_CURRENT_DESKTOP=niri
    LIBSEAT_LOGLEVEL=debug
    EOF

  - |
    install -Dm644 /dev/stdin \
      "%{install-root}%{indep-libdir}/environment.d/90-krytis-session.conf" <<'EOF'
    XDG_SESSION_TYPE=wayland
    XDG_CURRENT_DESKTOP=niri
    XDG_SESSION_DESKTOP=niri
    GSK_RENDERER=vulkan
    GDK_BACKEND=wayland
    EGL_PLATFORM=wayland
    CLUTTER_BACKEND=wayland
    MOZ_ENABLE_WAYLAND=1
    MOZ_DBUS_REMOTE=1
    GTK_IM_MODULE=simple
    QT_AUTO_SCREEN_SCALE_FACTOR=1
    QT_WAYLAND_FORCE_DPI=physical
    ELECTRON_OZONE_PLATFORM_HINT=auto
    _JAVA_AWT_WM_NONREPARENTING=1
    EOF

  - |
    install -Dm644 /dev/stdin \
      "%{install-root}%{sysconfdir}/systemd/journald.conf.d/10-persist.conf" <<'EOF'
    [Journal]
    Storage=persistent
    SyncIntervalSec=5s
    EOF

  - "%{install-extra}"
