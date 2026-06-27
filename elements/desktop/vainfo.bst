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
  ref: 2.23.0-0-g5896b6779d36f83bf483aff62da8aae30ba8d664
