kind: meson

build-depends:
- freedesktop-sdk.bst:public-stacks/buildsystem-meson.bst
- freedesktop-sdk.bst:components/pkg-config.bst
# stb and nlohmann-json are genuinely header-only (verified: no .so in
# either artifact) — compile-time only. tomlplusplus is NOT: fdsdk builds
# it as a shared library (libtomlplusplus.so.3, TOML_SHARED_LIB=1 in
# noctalia's own meson flags), so it belongs in `depends` below, not here.
- desktop/stb.bst
- desktop/nlohmann-json.bst

depends:
- freedesktop-sdk.bst:public-stacks/runtime-gnu.bst
- gnome-build-meta.bst:sdk/gtk.bst
- freedesktop-sdk.bst:components/pipewire.bst
- freedesktop-sdk.bst:components/polkit.bst
- freedesktop-sdk.bst:components/wireplumber.bst
- freedesktop-sdk.bst:components/tomlplusplus.bst
# libical: shared (libical.so), required by upstream meson.build:98 as of
# v5.0.0-beta.7 — same reasoning as tomlplusplus, so `depends`, not
# `build-depends`. Added after #401's ref bump landed without it and broke
# `mise build` on main (#412).
- freedesktop-sdk.bst:components/libical.bst
- freedesktop-sdk.bst:components/libsecret.bst
- desktop/libsodium.bst
- desktop/libqalculate.bst
- desktop/md4c.bst
- desktop/sdbus-cpp.bst

# Upstream noctalia-dev/noctalia, release tags v*.
#
# History: repo was renamed from noctalia-shell to noctalia as of 2026.
# We previously pinned a kitten-lily fork commit for
# fix/wifi-persist-polkit-async (async-dispatch AddAndActivateConnection2
# so a slow polkit prompt doesn't freeze the UI and drop the memory-only
# connection before persistConnectionToDisk()). Upstream commit 18e36ede3
# ("separate VPN from physical link state, async NM calls, safe proxy
# rebinds") independently made this same call async, so that fork pin was
# dropped. Upstream's async dispatch falls back to sdbus-c++'s default
# timeout; manually verified this is not an issue in practice.
#
# From 2026-08 to 2026-11 this element was also pinned to the kitten-lily/noctalia
# fork's feat/system-prompter branch, for a native org.gnome.keyring.SystemPrompter
# (and gnome-build-meta.bst:sdk/gcr.bst for its GcrSecretExchange). Upstream closed
# that proposal unmerged (noctalia-dev/noctalia#4951, 2026-11-02: secrets are out
# of noctalia's scope), and the standalone desktop/krytis-prompter.bst replaced it
# in #1502. The rebase history is in docs/design/secrets-service.md and
# docs/skills/desktop.md § noctalia (shell) build dependencies.
sources:
- kind: git_repo
  url: github:noctalia-dev/noctalia.git
  track: v*
  exclude:
  - '*rc*'
  - '*alpha*'
  - '*beta*'
  ref: v5.4.1-0-g815aebe1cfd79c9a18197441eea92f0b275035fc
# launch_apps_as_systemd_services defaults to true (upstream: false). With
# false, every app started from the launcher, dock or taskbar is a child of
# noctalia and lives in its cgroup. config/noctalia-service.bst runs noctalia
# in session.slice, so those apps would leave systemd-oomd's reach
# (config/oomd.bst arms app.slice only) and die whenever noctalia restarts.
# A struct default, not a settings.toml seed: /etc/skel only reaches new
# accounts, and the schema loader keeps the struct default for a missing key.
# An explicit `false` in a user's settings.toml still wins (#1253).
- kind: patch
  path: patches/noctalia/launch-apps-as-systemd-services-by-default.patch

variables:
  # tests=disabled: noctalia's meson.build enables `tests: auto` unit test
  # binaries for debug buildtypes (freedesktop-sdk's default). One of them,
  # input_password_mode_test, fails to link against v5.0.0-beta.3 — its
  # meson.build sources list is missing theme/fixed_palette.cpp,
  # theme/contrast.cpp and render/core/color.cpp (undefined reference to
  # expandFixedPalettes/applyTerminalPalette/relativeLuminance). We don't
  # ship or run these test binaries, so disable the option rather than
  # patch upstream's meson.build.
  meson-local: >-
    -Djemalloc=disabled -Dtests=disabled
