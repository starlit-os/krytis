# presence-bridge: host-side game detection for sandboxed (flatpak) Discord
# clients, which cannot see host PIDs (#595). Design and rationale:
# docs/design/presence-bridge.md.
#
# Installed but NOT enabled, by maintainer decision on #1152. That takes an
# explicit `disable` user-preset rule, not just the absence of an `enable` one:
# the image's global preset step enables every user unit with an [Install]
# section that no rule matches. Without the rule this unit shipped as
# /etc/systemd/user/graphical-session.target.wants/presence-bridge.service
# (docs/skills/bst.md § User units fall through too).
#
# Users opt in with `mise presence-bridge:enable` (and out with
# `mise presence-bridge:disable`); those are system mise tasks declared in
# /etc/mise/conf.d/presence-bridge.toml, which mise reads without any
# /etc/mise/config.toml entry (docs/skills/bst.md § System-wide mise tasks via
# BST element). `systemctl --user enable` writes ~/.config/systemd/user, which
# the preset never touches.
#
# The unit file is upstream's own systemd/presence-bridge.service, whose
# ExecStart=/usr/bin/presence-bridge already matches %{bindir}.
#
# Updates: the git_repo source tracks release-plz's v* tags, and
# `bst source track` regenerates the cargo2 refs from the new tag's Cargo.lock
# in the same pass. Listed in the track matrix of
# .github/workflows/track-bst-sources.yml.
kind: manual

build-depends:
- freedesktop-sdk.bst:components/rust.bst
- freedesktop-sdk.bst:public-stacks/buildsystem-make.bst

depends:
- freedesktop-sdk.bst:public-stacks/runtime-gnu.bst
- core/mise.bst

variables:
  cargo-home: '%{build-root}/.cargo'

config:
  build-commands:
  - |
    export CARGO_HOME="%{cargo-home}"
    cargo build --release --locked

  install-commands:
  - install -Dm755 target/release/presence-bridge "%{install-root}%{bindir}/presence-bridge"
  - |
    install -Dm644 systemd/presence-bridge.service \
      "%{install-root}%{indep-libdir}/systemd/user/presence-bridge.service"
  - |
    install -Dm644 /dev/null \
      "%{install-root}%{indep-libdir}/systemd/user-preset/80-presence-bridge.preset"
    cat > "%{install-root}%{indep-libdir}/systemd/user-preset/80-presence-bridge.preset" <<'EOF'
    disable presence-bridge.service
    EOF
  - |
    install -Dm644 /dev/null "%{install-root}%{sysconfdir}/mise/conf.d/presence-bridge.toml"
    cat > "%{install-root}%{sysconfdir}/mise/conf.d/presence-bridge.toml" <<'EOF'
    [tasks."presence-bridge:enable"]
    run = "systemctl --user enable --now presence-bridge.service"
    description = "Start presence-bridge now and at every login (Discord presence for flatpak clients)"

    [tasks."presence-bridge:disable"]
    run = "systemctl --user disable --now presence-bridge.service"
    description = "Stop presence-bridge and keep it from starting at login"
    EOF
  - "%{install-extra}"

sources:
- kind: git_repo
  url: github:kitten-lily/presence-bridge.git
  track: v*
  exclude:
  - '*rc*'
  - '*alpha*'
  - '*beta*'
  ref: v0.3.0-0-gcd6bac8b3b421d42074f520c38beac36fe2afb64
- kind: cargo2
  url: crates:crates
  ref:
  - kind: registry
    name: adler2
    version: 2.0.1
    sha: 320119579fcad9c21884f5c4861d16174d0e06250625266f50fe6898340abefa
  - kind: registry
    name: base64
    version: 0.23.1
    sha: ac07cdecf99051d9a5238b80f35af32cdeba5b336e55d957b318b50137e18da5
  - kind: registry
    name: bytes
    version: 1.12.1
    sha: fc652a48c352aef3ea3aed32080501cf3ef6ed5da78602a020c991775b0aff04
  - kind: registry
    name: cc
    version: 1.9.0
    sha: 877bf67ac8e52449eb2f9e98a344ea163beb70dd1f9eebe3cc5357dcfeaee4df
  - kind: registry
    name: cfg-if
    version: 1.0.5
    sha: 4e7648175b45a9a48536d676f68d918270699102aa8dab5496df06904c914600
  - kind: registry
    name: crc32fast
    version: 1.5.2
    sha: 01a7799fd6b852db0e61728dde9a204c423b44d689dbd432522543614b490e78
  - kind: registry
    name: find-msvc-tools
    version: 0.1.15
    sha: 1c66915cc5391097de7a2b0b972e8505aa33c0df401fd3a6811dbdb32881ba48
  - kind: registry
    name: flate2
    version: 1.1.10
    sha: 6e634e2e0ebac1ee034020da1ca582e17ffe4e0f5e985823721e168928136dcb
  - kind: registry
    name: getrandom
    version: 0.2.17
    sha: ff2abc00be7fca6ebc474524697ae276ad847ad0a6b3faa4bcb027e9a4614ad0
  - kind: registry
    name: http
    version: 1.5.0
    sha: 918d3568bebf352712bc2ef3d46a8bcf1a75b373be6539de198e9105cbbf9ce0
  - kind: registry
    name: httparse
    version: 1.10.1
    sha: 6dbf3de79e51f3d586ab4cb9d5c3e2c14aa28ed23d180cf89b4df0454a69cc87
  - kind: registry
    name: itoa
    version: 1.0.18
    sha: 8f42a60cbdf9a97f5d2305f08a87dc4e09308d1276d28c869c684d7777685682
  - kind: registry
    name: libc
    version: 0.2.191
    sha: 65cd87c9a6d60536580b316ad985726104730a5151c99845f2490428ef91240a
  - kind: registry
    name: log
    version: 0.4.34
    sha: f9f8bd3e56ce4dfc153cf470fffbfa98c7620958b312ca5c3a4b8d5181fd13c6
  - kind: registry
    name: memchr
    version: 2.8.3
    sha: cf8baf1c55e62ffcace7a9f06f4bd9cd3f0c4beb022d3b367256b91b87513d98
  - kind: registry
    name: miniz_oxide
    version: 0.9.1
    sha: b63fbc4a50860e98e7b2aa7804ded1db5cbc3aff9193adaff57a6931bf7c4b4c
  - kind: registry
    name: once_cell
    version: 1.21.4
    sha: 9f7c3e4beb33f85d45ae3e3a1792185706c8e16d043238c593331cc7cd313b50
  - kind: registry
    name: percent-encoding
    version: 2.3.2
    sha: 9b4f627cb1b25917193a259e49bdad08f671f8d9708acfd5fe0a8c1455d87220
  - kind: registry
    name: proc-macro2
    version: 1.0.107
    sha: 985e7ec9bb745e6ce6535b544d84d6cd6f7ad8bd711c398938ae983b91a766d9
  - kind: registry
    name: quote
    version: 1.0.47
    sha: 1fbf4db142a473a8d80c26bbf18454ed458bf8d26c8219c331daecfdbd079001
  - kind: registry
    name: ring
    version: 0.17.14
    sha: a4689e6c2294d81e88dc6261c768b63bc4fcdb852be6d1352498b114f61383b7
  - kind: registry
    name: rustls
    version: 0.23.46
    sha: 48e13bd8c0e9365c43cfa5c9e8f9ad49d3c8444926c9aac819e0e4dc503c8fdf
  - kind: registry
    name: rustls-pki-types
    version: 1.15.1
    sha: 2f4925028c7eb5d1fcdaf196971378ed9d2c1c4efc7dc5d011256f76c99c0a96
  - kind: registry
    name: rustls-webpki
    version: 0.103.16
    sha: 4443b1b6d39d7c663139942cc4558262562d2c84123bb6282ef177009ca8b281
  - kind: registry
    name: serde
    version: 1.0.229
    sha: 4148590afebada386688f18773da617792bf2ef03ffc1e4cbd2b1d45b023e0ba
  - kind: registry
    name: serde_core
    version: 1.0.229
    sha: 67dca2c9c51e58a4791a4b1ed58308b39c64224d349a935ab5039aa360942a48
  - kind: registry
    name: serde_derive
    version: 1.0.229
    sha: e7a5d71263a5a7d47b41f6b3f06ba276f10cc18b0931f1799f710578e2309348
  - kind: registry
    name: serde_json
    version: 1.0.154
    sha: e7e9cc8b1b85264074fbcc02a88680c4096b1e47df8f739dceb03bf482f04bd6
  - kind: registry
    name: shlex
    version: 2.0.1
    sha: f8fadd59c855ef2080decdef8ff161eb6661b86933c9d82e5ba29dc602a55aba
  - kind: registry
    name: simd-adler32
    version: 0.3.10
    sha: 3a219298ac11a56ea9a6d2120044824d6f01aeb034955e7af7bc16858527deea
  - kind: registry
    name: subtle
    version: 2.6.1
    sha: 13c2bddecc57b384dee18652358fb23172facb8a2c51ccc10d74c157bdea3292
  - kind: registry
    name: syn
    version: 3.0.9
    sha: d78c8dee4c7bf0e14673097256fed6142ce9d3b85a408189d07482442145823b
  - kind: registry
    name: unicode-ident
    version: 1.0.27
    sha: a2c754d6c33795a1c324727428e5a7dedb5b06195f9890bdbcba760d3e246563
  - kind: registry
    name: untrusted
    version: 0.9.0
    sha: 8ecb6da28b8a351d773b68d5825ac39017e680750f980f3a1a85cd8dd28a47c1
  - kind: registry
    name: ureq
    version: 3.5.0
    sha: cde93ff05758a36a851a398a772b0b79a82fbe3c186a46f2696baaeaf84c966b
  - kind: registry
    name: ureq-proto
    version: 0.6.5
    sha: 841583fc36089d7d59419568ae157f43a5a03a2e5a81ba87c77d1596ef46e922
  - kind: registry
    name: utf8-zero
    version: 0.8.1
    sha: b8c0a043c9540bae7c578c88f91dda8bd82e59ae27c21baca69c8b191aaf5a6e
  - kind: registry
    name: wasi
    version: 0.11.1+wasi-snapshot-preview1
    sha: ccf3ec651a847eb01de73ccad15eb7d99f80485de043efb2f370cd654f4ea44b
  - kind: registry
    name: webpki-roots
    version: 1.0.10
    sha: 1c1c8e20c8a38fc7d65abfe74eb7280e4aa667e8eec8bc84996d2874810748d9
  - kind: registry
    name: windows-sys
    version: 0.52.0
    sha: 282be5f36a8ce781fad8c8ae18fa3f9beff57ec1b52cb3de0789201425d9a33d
  - kind: registry
    name: windows-targets
    version: 0.52.6
    sha: 9b724f72796e036ab90c1021d4780d4d3d648aca59e491e6b98e725b84e99973
  - kind: registry
    name: windows_aarch64_gnullvm
    version: 0.52.6
    sha: 32a4622180e7a0ec044bb555404c800bc9fd9ec262ec147edd5989ccd0c02cd3
  - kind: registry
    name: windows_aarch64_msvc
    version: 0.52.6
    sha: 09ec2a7bb152e2252b53fa7803150007879548bc709c039df7627cabbd05d469
  - kind: registry
    name: windows_i686_gnu
    version: 0.52.6
    sha: 8e9b5ad5ab802e97eb8e295ac6720e509ee4c243f69d781394014ebfe8bbfa0b
  - kind: registry
    name: windows_i686_gnullvm
    version: 0.52.6
    sha: 0eee52d38c090b3caa76c563b86c3a4bd71ef1a819287c19d586d7334ae8ed66
  - kind: registry
    name: windows_i686_msvc
    version: 0.52.6
    sha: 240948bc05c5e7c6dabba28bf89d89ffce3e303022809e73deaefe4f6ec56c66
  - kind: registry
    name: windows_x86_64_gnu
    version: 0.52.6
    sha: 147a5c80aabfbf0c7d901cb5895d1de30ef2907eb21fbbab29ca94c5b08b1a78
  - kind: registry
    name: windows_x86_64_gnullvm
    version: 0.52.6
    sha: 24d5b23dc417412679681396f2b49f3de8c1473deb516bd34410872eff51ed0d
  - kind: registry
    name: windows_x86_64_msvc
    version: 0.52.6
    sha: 589f6da84c646204747d1270a2a5661ea66ed1cced2631d546fdfb155959f9ec
  - kind: registry
    name: zeroize
    version: 1.9.1
    sha: e13084392c5e4bc371903e2935a5eaeed24905a7511356b883835e18a78f6879
  - kind: registry
    name: zlib-rs
    version: 0.6.8
    sha: b268e58e7c693d7c271f93ffc4ba3b380412554231c85bf61ca7af91042a4112
  - kind: registry
    name: zmij
    version: 1.0.23
    sha: 29666d0abbfad1e3dc4dcf6144730dd3a3ab225bbbdac83319345b1b44ccfc1b
