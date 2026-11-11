kind: manual

# Ships the xwayland-satellite systemd user service and enables it via preset.
#
# The gnome-build-meta cargo kind only runs `cargo install`, which installs the
# binary to /usr/bin but does NOT install upstream service files from resources/.
# The upstream service file also hardcodes /usr/local/bin — wrong for fdsdk
# installs. We ship a corrected copy here.
#
# niri only (#1566). WantedBy=graphical-session.target would also start it
# under Umbriel, which binds graphical-session.target too
# (umbriel-session.target) but runs wlroots' own Xwayland (#1040). Two X
# servers would leave X11 apps with two possible DISPLAYs. ExecCondition reads
# XDG_CURRENT_DESKTOP from the user manager, which each compositor imports
# before graphical-session.target starts (niri's import_environment() before
# READY; umbriel's sessionEnvironmentCommand before umbriel-session.target).
# The doubled dollar hands the expansion to sh instead of systemd. A failing
# ExecCondition skips the unit cleanly; it isn't a failure. This element goes
# away with niri (#1567).

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
      "%{install-root}%{indep-libdir}/systemd/user/xwayland-satellite.service"
    cat > "%{install-root}%{indep-libdir}/systemd/user/xwayland-satellite.service" <<'EOF'
    [Unit]
    Description=Xwayland outside your Wayland
    BindsTo=graphical-session.target
    PartOf=graphical-session.target
    After=graphical-session.target
    Requisite=graphical-session.target

    [Service]
    Type=notify
    NotifyAccess=all
    ExecCondition=/usr/bin/sh -c 'test "$${XDG_CURRENT_DESKTOP:-}" = niri'
    ExecStart=/usr/bin/xwayland-satellite
    StandardOutput=journal

    [Install]
    WantedBy=graphical-session.target
    EOF
  - |
    install -Dm644 /dev/null \
      "%{install-root}%{indep-libdir}/systemd/user-preset/80-xwayland-satellite.preset"
    cat > "%{install-root}%{indep-libdir}/systemd/user-preset/80-xwayland-satellite.preset" <<'EOF'
    enable xwayland-satellite.service
    EOF
  - '%{install-extra}'
