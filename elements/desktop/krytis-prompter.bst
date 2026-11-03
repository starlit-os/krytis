# krytis-prompter: a standalone, D-Bus-activated org.gnome.keyring.SystemPrompter
# (GTK4 dialog on a gtk4-layer-shell overlay). oo7 calls it for every unlock
# prompt PAM can't answer. First-party repo kitten-lily/krytis-prompter, not a
# fork (#1502). Design and rationale: docs/design/secrets-service.md
# § A standalone prompter: krytis-prompter.
#
# Activation, not autostart. The bus starts it on the first BeginPrompting
# through share/dbus-1/services/org.gnome.keyring.SystemPrompter.service
# (SystemdService=krytis-prompter.service), and it exits after 60 s with no
# prompt open. Its user unit has no [Install] section, so the image's global
# user preset has nothing to enable (docs/skills/bst.md § User units fall
# through too).
#
# Until #1502 Phase 3, noctalia's fork prompter (desktop/noctalia.bst) also
# serves the name and, being spawned at session start, owns it whenever
# noctalia runs. krytis-prompter claims the name with DO_NOT_QUEUE and exits
# if it is taken, so the two never fight: this element is what answers while
# noctalia is stopped or restarting.
#
# Install rules mirror upstream's `mise run install` (mise/tasks/install),
# which this sandbox has no mise to run.
#
# Updates: the git_repo source tracks release-plz's v* tags, and
# `bst source track` regenerates the cargo2 refs from the new tag's Cargo.lock
# in the same pass. Listed in the track matrix of
# .github/workflows/track-bst-sources.yml.
kind: manual

build-depends:
- freedesktop-sdk.bst:components/rust.bst
- freedesktop-sdk.bst:public-stacks/buildsystem-make.bst
# gtk4-sys, gtk4-layer-shell-sys and the glib -sys crates find their C
# libraries through pkg-config.
- freedesktop-sdk.bst:components/pkg-config.bst

depends:
- freedesktop-sdk.bst:public-stacks/runtime-gnu.bst
- gnome-build-meta.bst:sdk/gtk.bst
# libgcr-4.so.4: GcrSecretExchange does the sx-aes-1 handshake over FFI, so
# krytis carries no crypto of its own. gcr-4, not sdk/gcr-3.bst
# (docs/skills/pam.md § Manual unlock on niri needs a GCR SystemPrompter).
- gnome-build-meta.bst:sdk/gcr.bst
# Linked by the gtk4-layer-shell crate directly; no introspection needed
# (docs/skills/pam.md § A Rust prompter … passes against oo7 and gcr's client).
- desktop/gtk4-layer-shell.bst

variables:
  cargo-home: '%{build-root}/.cargo'

config:
  build-commands:
  - |
    export CARGO_HOME="%{cargo-home}"
    cargo build --release --locked

  install-commands:
  - install -Dm755 target/release/krytis-prompter "%{install-root}%{bindir}/krytis-prompter"
  - |
    install -Dm644 data/org.gnome.keyring.SystemPrompter.service \
      "%{install-root}%{datadir}/dbus-1/services/org.gnome.keyring.SystemPrompter.service"
  - |
    install -Dm644 systemd/krytis-prompter.service \
      "%{install-root}%{indep-libdir}/systemd/user/krytis-prompter.service"
  - "%{install-extra}"

sources:
- kind: git_repo
  url: github:kitten-lily/krytis-prompter.git
  track: v*
  exclude:
  - '*rc*'
  - '*alpha*'
  - '*beta*'
  ref: v0.1.1-0-g41cf632dd6f26aebecdc1e30ebc27e9bda98b6a9
- kind: cargo2
  url: crates:crates
  ref:
  - kind: registry
    name: async-trait
    version: 0.1.92
    sha: 82f6aeea286b8eb4dd3431a1be1b59d290ace00f5bfd8e2a159bc2a05e2c1667
  - kind: registry
    name: autocfg
    version: 1.5.1
    sha: f2032f911046de80f0a198e0901378627c33f59ea0ac00e363d481118bd70a53
  - kind: registry
    name: bitflags
    version: 2.13.2
    sha: 3ded4057c258ba199e2d26386d3af3780957ecaee6c4ef4041c6b4b8b97c0b06
  - kind: registry
    name: bumpalo
    version: 3.20.3
    sha: 72f5acc6cb2ba439de613abc23857ec3d78374d8ed5ac84e9d11336e87da8649
  - kind: registry
    name: bytes
    version: 1.12.1
    sha: fc652a48c352aef3ea3aed32080501cf3ef6ed5da78602a020c991775b0aff04
  - kind: registry
    name: cairo-rs
    version: 0.22.9
    sha: df683f1d30b457964673a5541a4603208ef95ab6873d2a55871895cf310f3b56
  - kind: registry
    name: cairo-sys-rs
    version: 0.22.9
    sha: ee548131103ad8f698c6725669647b9c757b3b66992dd6a026037596417bee21
  - kind: registry
    name: cfg-expr
    version: 0.20.10
    sha: 9ba9e9ec16c447027685b1f897b720e18e9a8afd00bd7332c483537e38086c9f
  - kind: registry
    name: cfg-if
    version: 1.0.5
    sha: 4e7648175b45a9a48536d676f68d918270699102aa8dab5496df06904c914600
  - kind: registry
    name: endi
    version: 1.1.1
    sha: 66b7e2430c6dff6a955451e2cfc438f09cea1965a9d6f87f7e3b90decc014099
  - kind: registry
    name: equivalent
    version: 1.0.3
    sha: 00d174d5400e5e8fd687ad1049e2f578285fa914201b1af7e8b112a4546bd826
  - kind: registry
    name: errno
    version: 0.3.14
    sha: 39cab71617ae0d63f51a36d69f866391735b51691dbda63cf6f96d042b63efeb
  - kind: registry
    name: fastrand
    version: 2.5.0
    sha: da7c62ceae207dd37ea5b845da6a0696c799f85e97da1ab5b7910be3c1c80223
  - kind: registry
    name: field-offset
    version: 0.3.6
    sha: 38e2275cc4e4fc009b0669731a1e5ab7ebf11f469eaede2bab9309a5b4d6057f
  - kind: registry
    name: futures-channel
    version: 0.3.34
    sha: b1f9e3d69d39e4862ffed03ed071a76f9a13ba1d9109d355b0f0aa6b15e393c4
  - kind: registry
    name: futures-core
    version: 0.3.34
    sha: 92d699e522242e69e3003b94ecc1f960f3a5e015aa7c5d7486e65ad01dd94f5e
  - kind: registry
    name: futures-executor
    version: 0.3.34
    sha: 031b47cf1a3c6cc8bc2fc76cd437f521619387907d469316e7c0bc278f1f5432
  - kind: registry
    name: futures-io
    version: 0.3.34
    sha: 53c0fa8157de1303bfffdaa1cc2a673bfffb60102f76b0ef4441659124373fed
  - kind: registry
    name: futures-macro
    version: 0.3.34
    sha: 9fb9654ba8355388abeb8dcb4fc62f511300867002afc858860463bdd9fe0c44
  - kind: registry
    name: futures-task
    version: 0.3.34
    sha: cd417de3d1d015fc3bfd2b1ea46dfc7bab72ef86f1cc7cc9c78e728b34a6d1fd
  - kind: registry
    name: futures-util
    version: 0.3.34
    sha: 0d50a92467f8ba5dd6e3ee5d4bd04d73ab2e4e1c44474a0674821dfce14b79bc
  - kind: registry
    name: gdk-pixbuf
    version: 0.22.0
    sha: 25f420376dbee041b2db374ce4573892a36222bb3f6c0c43e24f0d67eae9b646
  - kind: registry
    name: gdk-pixbuf-sys
    version: 0.22.9
    sha: 9d5209294ba3775f9b650bf78bfadeba4332089f2329b3e2f6ce0a4957a45bff
  - kind: registry
    name: gdk4
    version: 0.11.5
    sha: e77c579bac9eff8b84c0625d5f533da6d69988c063062fe92c2e955ede8f28eb
  - kind: registry
    name: gdk4-sys
    version: 0.11.5
    sha: 3eff6238a30c1f198fb3c8d3d445fa7faf211d11d9075af0772e6e0ca32ae001
  - kind: registry
    name: getrandom
    version: 0.4.3
    sha: 300e883d756b2e4ec94e02791f39b04b522276138852cfc41d9fb7e904106099
  - kind: registry
    name: gio
    version: 0.22.10
    sha: 4620fbafdf19dba814473e19f18e75290cb3338662f6ae35f0402affd3b2b699
  - kind: registry
    name: gio-sys
    version: 0.22.9
    sha: 6c28739f914c15b87a9856000bed9cbd5b3a8afbca5e982d9a299e1601422cb5
  - kind: registry
    name: gl
    version: 0.14.0
    sha: a94edab108827d67608095e269cf862e60d920f144a5026d3dbcfd8b877fb404
  - kind: registry
    name: gl_generator
    version: 0.14.0
    sha: 1a95dfc23a2b4a9a2f5ab41d194f8bfda3cabec42af4e39f08c339eb2a0c124d
  - kind: registry
    name: glib
    version: 0.22.10
    sha: e4cf9e5bd8713f1990a92c422998826e0fb34824277b46bc59757373483c6694
  - kind: registry
    name: glib-macros
    version: 0.22.9
    sha: c9597c68fa7bdf4154a3079642cd21c4dccac0b0bdd2897d82861523bf91e7b9
  - kind: registry
    name: glib-sys
    version: 0.22.9
    sha: 99b38907e67e40dec9b60f858bcada952598719cb512a13eb13d6cdcd16f8295
  - kind: registry
    name: gobject-sys
    version: 0.22.9
    sha: 07595c9ba696bd9819cb6a8df39f08078f3dd679508fe052dd558492c2053834
  - kind: registry
    name: graphene-rs
    version: 0.22.8
    sha: eb856b9c558971c3f13ab692358926da710b046932a4e087aedcc35b040d7dff
  - kind: registry
    name: graphene-sys
    version: 0.22.9
    sha: 97842c7543828f98aa5583aa54fcda28aa84fa2b0f8c556142177f7bbb638057
  - kind: registry
    name: gsk4
    version: 0.11.5
    sha: eee23d7425c5281ec5a2f40f7b69384aac66c15861d990d248e9d9c9368be464
  - kind: registry
    name: gsk4-sys
    version: 0.11.5
    sha: 27900c92e47df410bbe43b51818104051e3409da43fb88547a41c0bafddfd39c
  - kind: registry
    name: gtk4
    version: 0.11.5
    sha: e0f8226c94dd0b65ba2e8fcd8ff402d380e890f6e5a6488e652a0158e827b9bf
  - kind: registry
    name: gtk4-layer-shell
    version: 0.8.1
    sha: 17c28ea0f4676fdaaae7ff2413a24d0d35c8657424f84856c1103c73454c9da4
  - kind: registry
    name: gtk4-layer-shell-sys
    version: 0.6.1
    sha: bcf19bb884ef0ef55b9e6b2b369c39b4fcc0c41e3a0c1cbc8c267720338b690b
  - kind: registry
    name: gtk4-macros
    version: 0.11.5
    sha: eb906c98f0b4cc9002594e337e83f40492aa6dca22c97242f13be5b046c5f338
  - kind: registry
    name: gtk4-sys
    version: 0.11.5
    sha: bd14af0137f269bdecee73404157d2a852f9651af7d68bd1023d3b8b914a14c3
  - kind: registry
    name: hashbrown
    version: 0.17.1
    sha: ed5909b6e89a2db4456e54cd5f673791d7eca6732202bbf2a9cc504fe2f9b84a
  - kind: registry
    name: heck
    version: 0.5.0
    sha: 2304e00983f87ffb38b55b444b5e3b60a884b5d30c0fca7d82fe33449bbe55ea
  - kind: registry
    name: hex
    version: 0.4.3
    sha: 7f24254aa9a54b5c858eaee2f5bccdb46aaf0e486a595ed5fd8f86ba55232a70
  - kind: registry
    name: indexmap
    version: 2.14.2
    sha: cc4e190f5d26ca7051642629da2c52fc03bde85a03197c99408dcd291734c855
  - kind: registry
    name: js-sys
    version: 0.3.107
    sha: 8dc09d2154098bbf4ef54eab6b117a3c24cbbffe94046b16ee6d6d4510584d3a
  - kind: registry
    name: khronos_api
    version: 3.1.0
    sha: e2db585e1d738fc771bf08a151420d3ed193d9d895a36df7f6f8a9456b911ddc
  - kind: registry
    name: libc
    version: 0.2.191
    sha: 65cd87c9a6d60536580b316ad985726104730a5151c99845f2490428ef91240a
  - kind: registry
    name: linux-raw-sys
    version: 0.12.1
    sha: 32a66949e030da00e8c7d4434b251670a91556f4144941d37452769c25d58a53
  - kind: registry
    name: log
    version: 0.4.35
    sha: 5d15f86d12da44cd8d4ec3c73984537eb7f4cadcb9776a575a0a8a05ca11005c
  - kind: registry
    name: memchr
    version: 2.8.3
    sha: cf8baf1c55e62ffcace7a9f06f4bd9cd3f0c4beb022d3b367256b91b87513d98
  - kind: registry
    name: memoffset
    version: 0.9.1
    sha: 488016bfae457b036d996092f6cb448677611ce4449e970ceaf42695203f218a
  - kind: registry
    name: mio
    version: 1.2.4
    sha: 1788edb87fdc09c7e26304471e2f5be8cdefb1b6930d6e3985fc02ff53bf86ee
  - kind: registry
    name: once_cell
    version: 1.21.4
    sha: 9f7c3e4beb33f85d45ae3e3a1792185706c8e16d043238c593331cc7cd313b50
  - kind: registry
    name: ordered-stream
    version: 0.2.0
    sha: 9aa2b01e1d916879f73a53d01d1d6cee68adbb31d6d9177a8cfce093cced1d50
  - kind: registry
    name: pango
    version: 0.22.9
    sha: 0b2022dbbd82e1c42bd950a6f1df9b98c796e725dce5ec275e03cbf9772e4efa
  - kind: registry
    name: pango-sys
    version: 0.22.9
    sha: ca02d64761b74d56cdd4b437db6d73dc95e6c0d40f27e1c707952c0f09052948
  - kind: registry
    name: pin-project-lite
    version: 0.2.17
    sha: a89322df9ebe1c1578d689c92318e070967d1042b512afbe49518723f4e6d5cd
  - kind: registry
    name: pkg-config
    version: 0.3.34
    sha: f6b464fbc74e149a392436b17d523f769e057cb6877f6a5c4618bc6f11800548
  - kind: registry
    name: proc-macro-crate
    version: 3.5.0
    sha: e67ba7e9b2b56446f1d419b1d807906278ffa1a658a8a5d8a39dcb1f5a78614f
  - kind: registry
    name: proc-macro2
    version: 1.0.107
    sha: 985e7ec9bb745e6ce6535b544d84d6cd6f7ad8bd711c398938ae983b91a766d9
  - kind: registry
    name: quote
    version: 1.0.47
    sha: 1fbf4db142a473a8d80c26bbf18454ed458bf8d26c8219c331daecfdbd079001
  - kind: registry
    name: r-efi
    version: 6.0.0
    sha: f8dcc9c7d52a811697d2151c701e0d08956f92b0e24136cf4cf27b57a6a0d9bf
  - kind: registry
    name: rustc_version
    version: 0.4.1
    sha: cfcb3a22ef46e85b45de6ee7e79d063319ebb6594faafcf1c225ea92ab6e9b92
  - kind: registry
    name: rustix
    version: 1.1.6
    sha: e5e76742e5294153d4dde1207dbec5bdd81eef6fabdc0d2118babadabfd858aa
  - kind: registry
    name: rustversion
    version: 1.0.23
    sha: cf54715a573b99ac80df0bc206da022bcd442c974952c7b9720069370852e21f
  - kind: registry
    name: semver
    version: 1.0.28
    sha: 8a7852d02fc848982e0c167ef163aaff9cd91dc640ba85e263cb1ce46fae51cd
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
    name: serde_repr
    version: 0.1.21
    sha: 8d3b1629de253c70a0508c3899572da79ca359fdab27c7920ff00406df418906
  - kind: registry
    name: serde_spanned
    version: 1.1.2
    sha: 4e7523beb55eece201a2356bee0bbca0d1ab466c14c07703b2e0ee6d42cb0c2c
  - kind: registry
    name: signal-hook-registry
    version: 1.4.8
    sha: c4db69cba1110affc0e9f7bcd48bbf87b3f4fc7c61fc9155afd4c469eb3d6c1b
  - kind: registry
    name: slab
    version: 0.4.12
    sha: 0c790de23124f9ab44544d7ac05d60440adc586479ce501c1d6d7da3cd8c9cf5
  - kind: registry
    name: smallvec
    version: 1.16.4
    sha: d0d5d4b1981b8bbbb7aed204cae5726d683d5d6ac7e74ec54122ea28f315e7c8
  - kind: registry
    name: socket2
    version: 0.6.5
    sha: c3d1e2c7f27f8d4cb10542a02c49005dbd6e93095799d6f3be745fae9f8fedd4
  - kind: registry
    name: syn
    version: 2.0.119
    sha: 872831b642d1a07999a962a351ed35b955ea2cfc8f3862091e2a240a84f17297
  - kind: registry
    name: syn
    version: 3.0.9
    sha: d78c8dee4c7bf0e14673097256fed6142ce9d3b85a408189d07482442145823b
  - kind: registry
    name: system-deps
    version: 8.0.0
    sha: 83779a5c956bcb6ba627a4ecf0a9d7625db47d7537e0892d97f712ac995648a3
  - kind: registry
    name: system-deps
    version: 9.0.1
    sha: db551ad38aac61d5e0343e0eeeb0163be3115c4e23b6a025959570ee0c03c67d
  - kind: registry
    name: target-lexicon
    version: 0.13.5
    sha: adb6935a6f5c20170eeceb1a3835a49e12e19d792f6dd344ccc76a985ca5a6ca
  - kind: registry
    name: tempfile
    version: 3.27.0
    sha: 32497e9a4c7b38532efcdebeef879707aa9f794296a4f0244f6f69e9bc8574bd
  - kind: registry
    name: tokio
    version: 1.54.1
    sha: b52fd3255258d26fac7264ab5a76b53c13367136dc011d3d6ad4f8ed070396a3
  - kind: registry
    name: toml
    version: 1.1.8+spec-1.1.0
    sha: 20489e00e4d8741d6be680764cc12e270655e375a20d1011e844a9c3379e678d
  - kind: registry
    name: toml_datetime
    version: 1.1.2+spec-1.1.0
    sha: 2b86d767906c6c42421dcba507eb9d203e779497710a47782a224bb871653053
  - kind: registry
    name: toml_edit
    version: 0.25.17+spec-1.1.0
    sha: e3641d5bbb5349a79e1020a242d251efbc546ad8048d133958323ce9c40a9c9c
  - kind: registry
    name: toml_parser
    version: 1.1.5+spec-1.1.0
    sha: baa693a8032d7e1cada7d0041e96126df243179ff061456783ac7f12bda4744c
  - kind: registry
    name: toml_writer
    version: 1.1.3+spec-1.1.0
    sha: 06bdbd8cfc056b8d2e2e85f29b56a3bdbecb527cef81eb39e3e7b98af4652770
  - kind: registry
    name: tracing
    version: 0.1.44
    sha: 63e71662fa4b2a2c3a26f570f037eb95bb1f85397f3cd8076caed2f026a6d100
  - kind: registry
    name: tracing-attributes
    version: 0.1.31
    sha: 7490cfa5ec963746568740651ac6781f701c9c5ea257c58e057f3ba8cf69e8da
  - kind: registry
    name: tracing-core
    version: 0.1.36
    sha: db97caf9d906fbde555dd62fa95ddba9eecfd14cb388e4f491a66d74cd5fb79a
  - kind: registry
    name: uds_windows
    version: 1.2.1
    sha: f2f6fb2847f6742cd76af783a2a2c49e9375d0a111c7bef6f71cd9e738c72d6e
  - kind: registry
    name: unicode-ident
    version: 1.0.27
    sha: a2c754d6c33795a1c324727428e5a7dedb5b06195f9890bdbcba760d3e246563
  - kind: registry
    name: uuid
    version: 1.29.0
    sha: 4a0e2d11620c50695fe12bbbfde96b3477fe606e7284c22d505c12ce51214514
  - kind: registry
    name: version-compare
    version: 0.2.1
    sha: 03c2856837ef78f57382f06b2b8563a2f512f7185d732608fd9176cb3b8edf0e
  - kind: registry
    name: wasi
    version: 0.11.1+wasi-snapshot-preview1
    sha: ccf3ec651a847eb01de73ccad15eb7d99f80485de043efb2f370cd654f4ea44b
  - kind: registry
    name: wasm-bindgen
    version: 0.2.130
    sha: a0181c14ddd6c7b8b0b0132a5f1ea2f32be0d893cd3ea97b6e3b28886b8a3d1c
  - kind: registry
    name: wasm-bindgen-macro
    version: 0.2.130
    sha: 6e931a02a39abdbf66966fc35902b5ed58344750a70885bed4ebb3d8eaf28ed9
  - kind: registry
    name: wasm-bindgen-macro-support
    version: 0.2.130
    sha: 2ca4b54280e455bd831e33a6b8e734baf432fe63fbc35c42ac14ce67a043a53a
  - kind: registry
    name: wasm-bindgen-shared
    version: 0.2.130
    sha: 3b1f9c3798725016c6ee5f2f57869ec0831e8bbc0ab0310a86e787e97f41389e
  - kind: registry
    name: windows-link
    version: 0.2.1
    sha: f0805222e57f7521d6a62e36fa9163bc891acd422f971defe97d64e70d0a4fe5
  - kind: registry
    name: windows-sys
    version: 0.61.2
    sha: ae137229bcbd6cdf0f7b80a31df61766145077ddf49416a728b02cb3921ff3fc
  - kind: registry
    name: winnow
    version: 1.0.4
    sha: 23b97319f7b8343df12cc98938e5c3eb436064524c8d2b4e30a1d3a36eecdf81
  - kind: registry
    name: xml-rs
    version: 0.8.29
    sha: e450f9b2ed1dff33c94c12589a87338689467b9c4f5d8a5710bd09a847d2c8a7
  - kind: registry
    name: zbus
    version: 6.2.1
    sha: 0ddb2961d9587ef9f24ad14cde1c3bc4c5edc9f1525932a8cffdd5bd98886eb9
  - kind: registry
    name: zbus_macros
    version: 6.2.1
    sha: 083b38add47c340fc12ec560124fb1d9c23acb584f7021099f85ec6587a03c54
  - kind: registry
    name: zbus_utils
    version: 6.1.0
    sha: af55e52da295311b368c45bcae221f020e28e97a2420360170ce389218e76ec7
  - kind: registry
    name: zcheapstr
    version: 1.2.0
    sha: 939f186d9ecebe044315a5cb6d6f78568bbc21152adc954d5a0c2f58bdbc9920
  - kind: registry
    name: zeroize
    version: 1.9.1
    sha: e13084392c5e4bc371903e2935a5eaeed24905a7511356b883835e18a78f6879
  - kind: registry
    name: zruntime
    version: 0.2.2
    sha: 23ef5ed7d628cdf0af82f93dfe03330a8e37383bf7422a1d3d6eb72326680be5
