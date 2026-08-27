kind: cmake

build-depends:
- freedesktop-sdk.bst:public-stacks/buildsystem-cmake.bst
- freedesktop-sdk.bst:components/pkg-config.bst

depends:
- freedesktop-sdk.bst:public-stacks/runtime-gnu.bst
- freedesktop-sdk.bst:components/systemd.bst

sources:
- kind: tar
  url: github_files:Kistler-Group/sdbus-cpp/archive/refs/tags/v2.3.1.tar.gz
  ref: 3a289eded586c26d06c1387de72c7bf7c809527a70d51ba6401fe61059b19626

variables:
  cmake-local: >-
    -DSDBUSCPP_BUILD_CODEGEN=OFF
    -DSDBUSCPP_BUILD_DOCS=OFF
    -DSDBUSCPP_BUILD_TESTS=OFF
    -DSDBUSCPP_BUILD_EXAMPLES=OFF
    -DSDBUSCPP_BUILD_LIBSYSTEMD=OFF
    -DBUILD_SHARED_LIBS=ON
