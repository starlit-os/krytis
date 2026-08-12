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
- freedesktop-sdk.bst:public-stacks/runtime-gnu.bst

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
    # from system-auth (pam_nologin, oo7).
    #
    # pam_systemd_home must come first and short-circuit on success. For a
    # systemd-homed user, homed owns the entire credential flow — FIDO2
    # included (rp_id io.systemd.home) — because the token's HMAC secret IS
    # the key material that decrypts the home area. pam_u2f cannot serve
    # homed login: its authfile lives inside the still-unmounted home, and
    # even a readable authfile would let `sufficient` end the stack before
    # homed ever activated the home.
    #
    # Without this line the greeter does NOT reject a homed user — it does
    # something worse. /etc/nsswitch.conf has `shadow: files systemd`, so
    # nss_systemd serves the record's privileged hashedPassword to root and
    # pam_unix authenticates the user just fine. The login succeeds, homed is
    # never asked to activate anything, and the session starts with the home
    # unmounted: NSS reports the home as `/` and substitutes
    # /usr/bin/systemd-home-fallback-shell for the real shell while the area is
    # inactive. Silent breakage, not a denial. Observed on real hardware.
    # See docs/skills/pam.md.
    #
    # The jump spec is upstream's (pam_systemd_home(8) EXAMPLE), not
    # `sufficient`: the module returns PAM_USER_UNKNOWN — not PAM_IGNORE —
    # for classic /etc/passwd users, so `default=ignore` is what lets them
    # fall through, while real homed auth failures stay fatal.
    #
    # pam_u2f would cover classic users here, before pam_unix (absent authfile
    # falls through) -- but it is DISABLED on this testbed branch as the
    # workaround for krytis#585.
    #
    # Why: pam_u2f is `sufficient`, so a successful FIDO2 auth ends the auth
    # stack before pam_unix runs. Nothing ever populates PAM_AUTHTOK, so
    # pam_oo7 has no password to stash and the login collection stays locked
    # for the whole session. That is survivable on its own -- except oo7 does
    # not report items in a locked collection (#585), so libsecret callers are
    # told the secret "does not exist" rather than being offered an unlock.
    # Silent wrong answers, not an error, and the prompter cannot help because
    # nothing ever asks for it.
    #
    # Forcing password login means pam_oo7 gets PAM_AUTHTOK, auto_start
    # unlocks the collection at login, and the collection is simply never
    # locked -- so #585 has nothing to bite on.
    #
    # This is a mitigation, not a fix. Anything that re-locks mid-session (a
    # `systemctl --user restart oo7-daemon`, an explicit lock) puts #585 back
    # in play. Restore this line once #585 is fixed upstream, or if this
    # branch is ever reworked to keep gnome-keyring.
    #
    # Only the *greeter* path is affected. sudo and sshd get pam_u2f from
    # config/u2f-config.bst (system-auth / password-auth), which is untouched,
    # so a FIDO2 key still works for sudo.

    auth       required     pam_nologin.so
    -auth      [success=done authtok_err=bad perm_denied=bad maxtries=bad default=ignore] pam_systemd_home.so
    # auth     sufficient   pam_u2f.so cue pinverification   # disabled: krytis#585
    auth       required     pam_unix.so
    auth       optional     pam_oo7.so

    account    required     pam_nologin.so
    -account   sufficient   pam_systemd_home.so
    account    required     pam_unix.so

    -password  sufficient   pam_systemd_home.so
    password   required     pam_unix.so sha512 shadow
    # No use_authtok: upstream's own example (oo7 pam/README.md) omits it on the
    # password line, and gh178 carried it over from the gnome-keyring line without
    # checking. pam_oo7 reads both the old and new password itself to re-encrypt
    # matching keyrings; use_authtok would only constrain where it may read from.
    -password  optional     pam_oo7.so

    # pam_systemd_home takes a reference on the home area so homed does not
    # deactivate it for the lifetime of the session.
    -session   optional     pam_systemd_home.so
    session    required     pam_loginuid.so
    session    optional     pam_keyinit.so force revoke
    session    required     pam_limits.so
    # pam_env must run before pam_systemd so that XDG_SESSION_TYPE=wayland
    # is visible when logind registers the session. Without it, logind sees
    # a tty-type session, denies the seat to libseat, and the compositor hangs.
    session    required     pam_env.so readenv=1
    session    required     pam_unix.so
    -session   optional     pam_systemd.so
    session    optional     pam_oo7.so auto_start
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

  # Named krytis-greetd.conf, NOT noctalia-greeter.conf: upstream
  # noctalia-greeter ships its own /usr/lib/tmpfiles.d/noctalia-greeter.conf
  # as of v1.1.0 (data/tmpfiles.d/, `d /var/lib/noctalia-greeter 0750 greeter
  # greeter -`), and two elements installing the same path is a
  # non-whitelisted overlap that fails oci/krytis/runtime.bst at staging.
  # /var/lib/noctalia-greeter is therefore upstream's to declare — its 0750 is
  # tighter than the 0755 krytis used to set, and nothing needs the looser
  # mode: greeter-config-seed.sh runs as root and chowns to greeter itself.
  # Only /var/lib/greetd is krytis's (greetd's own state dir, from the
  # sysusers home above).
  - |
    install -Dm644 /dev/stdin \
      "%{install-root}%{indep-libdir}/tmpfiles.d/krytis-greetd.conf" <<'EOF'
    d /var/lib/greetd 0750 greeter greeter -
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

  # Filename matters more than the directory here. journald.conf.d drop-ins are
  # merged in lexicographic order of *filename*, across /etc and /usr/lib alike —
  # /etc only beats /usr/lib for a file of the SAME name. freedesktop-sdk ships
  # /usr/lib/systemd/journald.conf.d/99-volatile-journal.conf (Storage=volatile),
  # so this file was previously named 10-persist.conf and lost: 10- sorted first,
  # 99- was applied last, and the image silently ran with a volatile journal that
  # vanished on every reboot. `systemd-analyze cat-config systemd/journald.conf`
  # shows the merge order and is the way to confirm this.
  #
  # zz- sorts after any numeric prefix, so it wins without having to masquerade
  # under upstream's filename.
  - |
    install -Dm644 /dev/stdin \
      "%{install-root}%{sysconfdir}/systemd/journald.conf.d/zz-krytis-persist.conf" <<'EOF'
    [Journal]
    Storage=persistent
    SyncIntervalSec=5s
    EOF

  - "%{install-extra}"
