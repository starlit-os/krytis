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
  ref: v4.7.1-0-gef0a1a40c30d164913f413c47de5bbd8383a6daa
