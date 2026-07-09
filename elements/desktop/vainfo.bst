kind: meson

build-depends:
- freedesktop-sdk.bst:public-stacks/buildsystem-meson.bst
- freedesktop-sdk.bst:components/pkg-config.bst

depends:
- freedesktop-sdk.bst:public-stacks/runtime-minimal.bst
- freedesktop-sdk.bst:components/libva.bst

variables:
  meson-local: >-
    -Ddrm=true
    -Dwayland=true
    -Dx11=false

sources:
- kind: git_repo
  url: github:intel/libva-utils.git
  track: '*.*.*'
  ref: 2.24.0-0-gc3ba9e07e61841f1bc2c9932d957b44e5827a852
