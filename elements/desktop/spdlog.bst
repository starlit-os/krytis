kind: cmake

# spdlog: fast C++ logging library, required by desktop/ananicy-cpp.bst. Not shipped
# by freedesktop-sdk (confirmed absent from the full elements/components/ tree, both
# 25.08.0 and master, via the GitLab API — alphabetically it isn't there between
# swig.bst and systemd-hwdb-maybe.bst). Vendored here with the same
# find_package-friendly shared-lib config nlohmann-json.bst and stb.bst use for other
# fdsdk gaps. Built against fdsdk's fmtlib.bst (SPDLOG_FMT_EXTERNAL=ON) rather than
# spdlog's own bundled fmt fork, so there is exactly one fmt runtime in the image.

build-depends:
- freedesktop-sdk.bst:public-stacks/buildsystem-cmake.bst
- freedesktop-sdk.bst:components/pkg-config.bst

depends:
- freedesktop-sdk.bst:public-stacks/runtime-gnu.bst
- freedesktop-sdk.bst:components/fmtlib.bst

variables:
  cmake-local: >-
    -DSPDLOG_BUILD_SHARED=ON
    -DSPDLOG_FMT_EXTERNAL=ON
    -DSPDLOG_INSTALL=ON
    -DSPDLOG_BUILD_EXAMPLE=OFF
    -DSPDLOG_BUILD_TESTS=OFF

sources:
- kind: git_repo
  url: github:gabime/spdlog.git
  track: v*
  ref: v1.17.0-0-g79524ddd08a4ec981b7fea76afd08ee05f83755d
