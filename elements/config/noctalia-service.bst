kind: manual
# Runs the noctalia shell as a systemd user service in session.slice (#1253).
#
# Why: config/oomd.bst arms systemd-oomd's memory-pressure kill on each user's
# app.slice. Both compositors used to start noctalia themselves, which put it in
# app.slice (niri: app-niri-noctalia-<pid>.scope, umbriel:
# app-umbriel-<pid>-<n>.scope), so oomd could kill the panel, launcher and
# lock screen together. session.slice is never an oomd candidate.
# files/niri/startup.kdl and files/umbriel/config.toml no longer start it.
#
# Ordering: both compositors import their session environment into the user
# manager before graphical-session.target is reached. niri.service is
# Type=notify and `niri --session` calls import_environment() before
# sd_notify(READY) (src/main.rs); umbriel imports WAYLAND_DISPLAY ...
# UMBRIEL_SOCKET and only then starts umbriel-session.target, which binds
# graphical-session.target (sessionEnvironmentCommand, src/server/server.cpp).
# niri-session and start-umbriel both import the whole login environment
# first, XDG_SESSION_ID included. noctalia needs that: outside a login-session
# scope, GetSessionByPID fails, and XDG_SESSION_ID is its only way to find the
# logind session for the Lock/Unlock signals (src/dbus/logind/logind_service.cpp).
# polkit accepts the agent from outside a session through sd_uid_get_display.
#
# ExecCondition: accounts created before #1253 have their own copy of
# ~/.config/niri/startup.kdl (config/niri-skel.bst copies it), still with
# `spawn-at-startup "noctalia"`. The image can't edit that copy. When the
# spawned instance is already running, the condition skips this unit cleanly
# instead of failing on noctalia's single-instance lock ("noctalia is already
# running", exit 1). Those accounts keep the old app.slice instance until the
# line is deleted.
#
# Restart=on-abnormal: restart after a crash or a kill (a kernel OOM kill
# included), but not after exit 1, which is also the duplicate-instance exit.
#
# KillMode stays control-group: since desktop/noctalia.bst's patch,
# launched apps go to their own app-<id>@<uuid>.service units in app.slice, so
# the only children left in this cgroup are noctalia's helpers and hooks.
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
      "%{install-root}%{indep-libdir}/systemd/user/noctalia.service"
    cat > "%{install-root}%{indep-libdir}/systemd/user/noctalia.service" <<'EOF'
    [Unit]
    Description=Noctalia desktop shell
    Documentation=https://github.com/noctalia-dev/noctalia
    PartOf=graphical-session.target
    After=graphical-session.target
    Requisite=graphical-session.target

    [Service]
    Slice=session.slice
    ExecCondition=/usr/bin/sh -c '! pgrep -x -U %U noctalia'
    ExecStart=/usr/bin/noctalia
    Restart=on-abnormal

    [Install]
    WantedBy=graphical-session.target
    EOF
  - |
    install -Dm644 /dev/null \
      "%{install-root}%{indep-libdir}/systemd/user-preset/80-noctalia.preset"
    cat > "%{install-root}%{indep-libdir}/systemd/user-preset/80-noctalia.preset" <<'EOF'
    enable noctalia.service
    EOF
