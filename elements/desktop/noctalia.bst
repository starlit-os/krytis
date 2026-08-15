kind: meson

build-depends:
- freedesktop-sdk.bst:public-stacks/buildsystem-meson.bst
- freedesktop-sdk.bst:components/pkg-config.bst
# stb and nlohmann-json are genuinely header-only (verified: no .so in
# either artifact) — compile-time only. tomlplusplus is NOT: fdsdk builds
# it as a shared library (libtomlplusplus.so.3, TOML_SHARED_LIB=1 in
# noctalia's own meson flags), so it belongs in `depends` below, not here.
- desktop/stb.bst
- freedesktop-sdk.bst:components/nlohmann-json.bst

depends:
- freedesktop-sdk.bst:public-stacks/runtime-minimal.bst
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
# gcr-4 (libgcr-4.so): shared, so `depends`. Required by the fork's
# src/dbus/secrets/secret_prompter.cpp, which links GcrSecretExchange for the
# "sx-aes-1" handshake that keeps prompted secrets off the bus in plaintext.
# NOTE: this is gcr-4 (gnome-build-meta.bst:sdk/gcr.bst), NOT the legacy
# sdk/gcr-3.bst. On main, gnome-keyring pulls gcr-3 in transitively for its
# own gcr-base-3 linkage (unrelated to the prompter binary), so gcr-prompter
# stays in the image as an inert fallback. Verified gcr-4 does not pull in
# GTK, and krytis ships GTK4 unconditionally anyway (niri.bst, ghostty.bst,
# nautilus) -- see PR #568.
#
# THIS BRANCH DIVERGES: stacks/desktop.bst swaps gnome-keyring for oo7, which
# takes gcr-3 -- and with it gcr-prompter -- out of the image entirely. That
# absence is the whole point: manual unlock has no legacy prompter to fall
# back on, so if it still works, noctalia answered. See stacks/desktop.bst
# and docs/skills/pam.md.
- gnome-build-meta.bst:sdk/gcr.bst

# Upstream noctalia-dev/noctalia. Releases tagged v* (v5.0.0-beta2 latest
# as of this pin). git_repo + track: v* lets bst source track follow tags.
#
# History: repo was renamed from noctalia-shell to noctalia as of 2026.
# We previously pinned a kitten-lily fork commit for
# fix/wifi-persist-polkit-async (async-dispatch AddAndActivateConnection2
# so a slow polkit prompt doesn't freeze the UI and drop the memory-only
# connection before persistConnectionToDisk()). Upstream commit 18e36ede3
# ("separate VPN from physical link state, async NM calls, safe proxy
# rebinds") independently made this same call async, so the fork pin was
# dropped. Upstream's async dispatch falls back to sdbus-c++'s default
# timeout; manually verified this is not an issue in practice.
#
# INTERIM PIN (2026-08-13): kitten-lily/noctalia branch feat/system-prompter,
# not yet upstreamed. Adds a native org.gnome.keyring.SystemPrompter provider
# so niri/noctalia sessions get keyring manual-unlock prompts without
# depending on gcr-3's legacy gcr-prompter binary. gnome-keyring stays the
# Secret Service provider here -- this is decoupled from the oo7 migration
# (#84), which is on hold pending upstream oo7 fixes; see PR #568. Revert to
#   url: github:noctalia-dev/noctalia.git
#   track: v*
# once the feature lands upstream (or is dropped). Tracking the branch
# instead of the v* tag glob means `bst source track` follows the branch
# head here, not releases -- expect more frequent auto-track PRs than usual
# until this is reverted.
sources:
- kind: git_repo
  url: github:kitten-lily/noctalia.git
  track: feat/system-prompter
  ref: v5.0.0-beta.8-38-gfcaf05e8496a8f26beb4eda441efc3a6eff171b8

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
