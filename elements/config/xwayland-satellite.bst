kind: manual

# Ships the xwayland-satellite systemd user service and enables it via preset.
#
# The gnome-build-meta cargo kind only runs `cargo install`, which installs the
# binary to /usr/bin but does NOT install upstream service files from resources/.
# The upstream service file also hardcodes /usr/local/bin — wrong for fdsdk
# installs. We ship a corrected copy here.

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
      "%{install-root}%{indep-libdir}/systemd/user/xwayland-satellite.service" <<'EOF'
    [Unit]
    Description=Xwayland outside your Wayland
    BindsTo=graphical-session.target
    PartOf=graphical-session.target
    After=graphical-session.target
    Requisite=graphical-session.target

    [Service]
    Type=notify
    NotifyAccess=all
    ExecStart=/usr/bin/xwayland-satellite
    StandardOutput=journal

    [Install]
    WantedBy=graphical-session.target
    EOF
  - |
    install -Dm644 /dev/stdin \
      "%{install-root}%{indep-libdir}/systemd/user-preset/80-xwayland-satellite.preset" <<'EOF'
    enable xwayland-satellite.service
    EOF
  - '%{install-extra}'
