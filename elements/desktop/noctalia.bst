kind: meson

build-depends:
- freedesktop-sdk.bst:public-stacks/buildsystem-meson.bst
- freedesktop-sdk.bst:components/pkg-config.bst

depends:
- freedesktop-sdk.bst:public-stacks/runtime-minimal.bst
- gnome-build-meta.bst:sdk/gtk.bst
- freedesktop-sdk.bst:components/pipewire.bst
- freedesktop-sdk.bst:components/polkit.bst
- freedesktop-sdk.bst:components/wireplumber.bst
- desktop/libqalculate.bst
- desktop/sdbus-cpp.bst

# Pinned to a specific commit on upstream `main` — no release tags exist on
# this repo. GitHub's archive/refs/heads/main.tar.gz regenerates on every push
# (sha256 changes with each commit), so we must pin to a full commit SHA.
# Update the commit and ref together when bumping.
# Note: repo was renamed from noctalia-shell to noctalia as of 2026.
#
# Back on upstream noctalia-dev/noctalia (dropped the kitten-lily fork pin).
# Our fork carried fix/wifi-persist-polkit-async (async-dispatch
# AddAndActivateConnection2 so a slow polkit prompt doesn't freeze the UI
# and drop the memory-only connection before persistConnectionToDisk()).
# Upstream commit 18e36ede3 ("separate VPN from physical link state, async
# NM calls, safe proxy rebinds") independently made this same call async,
# as part of a much larger rewrite of network_manager_service.cpp that our
# fork commit no longer rebases onto cleanly. Caveat: upstream's async
# dispatch has no explicit withTimeout (falls back to sdbus-c++'s ~25s
# default), whereas our fork used 120s to survive slower polkit prompts —
# watch for the connection still vanishing if the prompt runs long.
sources:
- kind: tar
  url: github_files:noctalia-dev/noctalia/archive/87db64f1ad856ded71a09bfae971025640a6034d.tar.gz
  ref: aa82651ad978f63cadf7c5618294ba49fd4dd82e07fad561de9d2d37cf549750

variables:
  meson-local: >-
    -Djemalloc=disabled
