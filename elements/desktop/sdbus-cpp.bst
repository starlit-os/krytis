kind: cmake

build-depends:
- freedesktop-sdk.bst:public-stacks/buildsystem-cmake.bst
- freedesktop-sdk.bst:components/pkg-config.bst

depends:
- freedesktop-sdk.bst:public-stacks/runtime-gnu.bst
- freedesktop-sdk.bst:components/systemd.bst

sources:
- kind: tar
  url: github_files:Kistler-Group/sdbus-cpp/archive/refs/tags/v2.4.0.tar.gz
  ref: 83aa631f6a51646ef3e7b12bb0d2705ae2059ae96c593d493621f27da46338ec

variables:
  cmake-local: >-
    -DSDBUSCPP_BUILD_CODEGEN=OFF
    -DSDBUSCPP_BUILD_DOCS=OFF
    -DSDBUSCPP_BUILD_TESTS=OFF
    -DSDBUSCPP_BUILD_EXAMPLES=OFF
    -DSDBUSCPP_BUILD_LIBSYSTEMD=OFF
    -DBUILD_SHARED_LIBS=ON
