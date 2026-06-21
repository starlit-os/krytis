kind: cmake

build-depends:
- freedesktop-sdk.bst:public-stacks/buildsystem-cmake.bst
- freedesktop-sdk.bst:components/pkg-config.bst

depends:
- freedesktop-sdk.bst:public-stacks/runtime-minimal.bst
- freedesktop-sdk.bst:components/systemd.bst

sources:
- kind: tar
  url: github_files:Kistler-Group/sdbus-cpp/archive/refs/tags/v2.2.1.tar.gz
  ref: da69a0104beb6e51415a59f1571a47beb1eacc65cc6027b250eb1cf13ff4f802

variables:
  cmake-local: >-
    -DSDBUSCPP_BUILD_CODEGEN=OFF
    -DSDBUSCPP_BUILD_DOCS=OFF
    -DSDBUSCPP_BUILD_TESTS=OFF
    -DSDBUSCPP_BUILD_EXAMPLES=OFF
    -DSDBUSCPP_BUILD_LIBSYSTEMD=OFF
    -DBUILD_SHARED_LIBS=ON
