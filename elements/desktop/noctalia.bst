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
  url: github_files:noctalia-dev/noctalia/archive/e61abbfb8892bfaf8e5b8f56f4f964e7862cc27f.tar.gz
  ref: 6294472bcd2b53a16c3dd55365a5db173e32658e3e8425b64780470de2114954

variables:
  meson-local: >-
    -Djemalloc=disabled
