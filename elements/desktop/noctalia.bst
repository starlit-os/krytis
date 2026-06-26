kind: meson

build-depends:
- freedesktop-sdk.bst:public-stacks/buildsystem-meson.bst
- freedesktop-sdk.bst:components/pkg-config.bst

depends:
- freedesktop-sdk.bst:public-stacks/runtime-minimal.bst
- gnome-build-meta.bst:sdk/gtk.bst
- freedesktop-sdk.bst:components/pipewire.bst
- freedesktop-sdk.bst:components/polkit.bst
- desktop/libqalculate.bst
- desktop/sdbus-cpp.bst

# Pinned to a specific commit on upstream `main` — no release tags exist on
# this repo. GitHub's archive/refs/heads/main.tar.gz regenerates on every push
# (sha256 changes with each commit), so we must pin to a full commit SHA.
# Update the commit and ref together when bumping.
# Note: repo was renamed from noctalia-shell to noctalia as of 2026.
sources:
- kind: tar
  url: github_files:noctalia-dev/noctalia/archive/78e528ba61704226208c06a6aea5f5971c5347d5.tar.gz
  ref: 894c98d1db7bcabc380679f4ddc201673fc69e7707a6d3bd444d57458a6b10a7

variables:
  meson-local: >-
    -Djemalloc=disabled
