# libtsm — Terminal-emulator State Machine library, required by kmscon.
#
# Upstream moved from the Aetf personal fork to the kmscon org
# (github.com/kmscon/libtsm). Meson build.

kind: meson

build-depends:
- freedesktop-sdk.bst:public-stacks/buildsystem-meson.bst
- freedesktop-sdk.bst:components/pkg-config.bst

depends:
- freedesktop-sdk.bst:public-stacks/runtime-gnu.bst

variables:
  meson-local: -Dtests=false

sources:
- kind: git_repo
  url: github:kmscon/libtsm.git
  track: v*
  ref: v4.8.0-0-gef2365d0f9f1a370d721a82470d69c3646fe97f0
