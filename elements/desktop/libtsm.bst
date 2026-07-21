# libtsm — Terminal-emulator State Machine library, required by kmscon.
#
# Upstream moved from the Aetf personal fork to the kmscon org
# (github.com/kmscon/libtsm). Meson build.

kind: meson

build-depends:
- freedesktop-sdk.bst:public-stacks/buildsystem-meson.bst
- freedesktop-sdk.bst:components/pkg-config.bst

depends:
- freedesktop-sdk.bst:public-stacks/runtime-minimal.bst

variables:
  meson-local: -Dtests=false

sources:
- kind: git_repo
  url: github:kmscon/libtsm.git
  track: v*
  ref: v4.6.0-0-ge1e4d296f0963d1641456f1f778f0ac090429a3e
