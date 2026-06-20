kind: make

build-depends:
- freedesktop-sdk.bst:components/rust.bst
- freedesktop-sdk.bst:public-stacks/buildsystem-make.bst
- freedesktop-sdk.bst:components/pkg-config.bst
- freedesktop-sdk.bst:extensions/mesa/mesa.bst

depends:
- freedesktop-sdk.bst:public-stacks/runtime-minimal.bst
- gnome-build-meta.bst:sdk/gtk.bst
- freedesktop-sdk.bst:components/libdisplay-info.bst
- freedesktop-sdk.bst:components/libinput.bst
- freedesktop-sdk.bst:components/libseat.bst
- freedesktop-sdk.bst:components/pipewire.bst
- freedesktop-sdk.bst:extensions/mesa/mesa.bst

variables:
  cargo-home: '%{build-root}/.cargo'
  # Mesa is installed under %{libdir}/GL/default.
  # %{libdir} expands to /usr/lib/%{gcc_triplet}, resolving the multiarch
  # triplet correctly for x86_64 and aarch64.
  mesa-gl-dir: '%{libdir}/GL/default/lib'

config:
  build-commands:
  - |
    mkdir -p .cargo
    cat > .cargo/config.toml <<'EOF'
    [source.crates-io]
    replace-with = "vendored-sources"

    [source."git+https://github.com/Smithay/smithay.git?rev=ff5fa7df392cecfba049ffed55cdaa4e98a8e7ef"]
    git = "https://github.com/Smithay/smithay.git"
    rev = "ff5fa7df392cecfba049ffed55cdaa4e98a8e7ef"
    replace-with = "vendored-sources"

    [source.vendored-sources]
    directory = "vendor"
    EOF
  - |
    export CARGO_HOME="%{cargo-home}"
    export CARGO_NET_OFFLINE=true
    export PKG_CONFIG_PATH="%{mesa-gl-dir}/pkgconfig:${PKG_CONFIG_PATH:-}"
    export LIBRARY_PATH="%{mesa-gl-dir}:${LIBRARY_PATH:-}"
    export LD_LIBRARY_PATH="%{mesa-gl-dir}:${LD_LIBRARY_PATH:-}"
    cargo build --release --frozen --locked --no-default-features --features "dbus xdp-gnome-screencast systemd"
  install-commands:
  - |
    install -Dm755 target/release/niri "%{install-root}%{bindir}/niri"
    install -Dm755 resources/niri-session "%{install-root}%{bindir}/niri-session"
    install -Dm644 resources/niri.desktop "%{install-root}%{datadir}/wayland-sessions/niri.desktop"
    install -Dm644 resources/niri-portals.conf "%{install-root}%{datadir}/xdg-desktop-portal/niri-portals.conf"
    install -Dm644 resources/niri.service "%{install-root}%{indep-libdir}/systemd/user/niri.service"
    install -Dm644 resources/niri-shutdown.target "%{install-root}%{indep-libdir}/systemd/user/niri-shutdown.target"
    %{install-extra}

sources:
- kind: tar
  url: github_files:niri-wm/niri/archive/refs/tags/v26.04.tar.gz
  ref: 134c602d8e0d53413a52d6cd58f9ce7e79a07d03288ee0a51ba1abd5db1b1ad9
- kind: tar
  url: github_files:niri-wm/niri/releases/download/v26.04/niri-26.04-vendored-dependencies.tar.xz
  base-dir: ""
  ref: 407c525cd78710e72455c48741756857ca47dc32910a42f82cd40992a34beed6
