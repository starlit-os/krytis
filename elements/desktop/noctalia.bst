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
- desktop/libqalculate.bst
- desktop/md4c.bst
- desktop/sdbus-cpp.bst

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
sources:
- kind: git_repo
  url: github:noctalia-dev/noctalia.git
  track: v*
  ref: v5.0.0-beta2-0-g32bcfb9c9783874c5c0f9709e3f741b07e54ca65

variables:
  meson-local: >-
    -Djemalloc=disabled
