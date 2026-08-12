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
# gcr-4 (libgcr-4.so): shared, so `depends`. Required by the fork's
# src/dbus/secrets/secret_prompter.cpp, which links GcrSecretExchange for the
# "sx-aes-1" handshake that keeps prompted secrets off the bus in plaintext.
# NOTE: this is gcr-4 (gnome-build-meta.bst:sdk/gcr.bst), NOT the legacy
# sdk/gcr-3.bst. Verified gcr-4 does not pull in GTK, and krytis ships GTK4
# unconditionally anyway (niri.bst, ghostty.bst, nautilus) -- see PR #568.
#
# This prompter is load-bearing, not a nicety. Since #594 swapped
# gnome-keyring for oo7 (stacks/desktop.bst), gcr-3 -- and with it the legacy
# gcr-prompter binary -- is out of the image entirely, so nothing else on the
# session bus can answer org.gnome.keyring.SystemPrompter. Without noctalia
# every libsecret caller that needs an unlock hangs rather than failing, and
# oo7 has no other way to ask for a password. See docs/skills/pam.md and
# docs/design/secrets-service.md.
- gnome-build-meta.bst:sdk/gcr.bst

# Upstream is noctalia-dev/noctalia, releases tagged v*. krytis does not track
# those tags today -- see the fork pin below.
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
# FORK PIN: kitten-lily/noctalia branch feat/system-prompter, not yet
# upstreamed (no PR opened against noctalia-dev/noctalia -- that needs an
# explicit instruction per AGENTS.md's Upstream Gate). It adds the native
# org.gnome.keyring.SystemPrompter provider that oo7 depends on for every
# unlock prompt, per the note above.
#
# Rebased onto upstream main 87b203c68 (v5.0.0-beta.8-135) on 2026-08-17: the
# 1722-line feature commit applied across 98 upstream commits with no source
# conflict. The only conflict was documentation -- upstream moved the
# dependency lists out of README.md into BUILDING.md, so the gcr-4 package
# names were ported there instead, including the newly added AerynOS entry.
#
# Revert to
#   url: github:noctalia-dev/noctalia.git
#   track: v*
# once the feature lands upstream (or is dropped). Tracking a branch instead
# of the v* tag glob means `bst source track` follows the branch head, not
# releases -- expect more frequent auto-track PRs than usual until then, and
# note that an unrelated commit on that branch changes what krytis ships.
sources:
- kind: git_repo
  url: github:kitten-lily/noctalia.git
  track: feat/system-prompter
  ref: v5.0.0-beta.8-137-g47c1df893246f0c6b736e11ca595daf39d04628d

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
