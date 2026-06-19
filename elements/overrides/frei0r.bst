kind: cmake

build-depends:
- freedesktop-sdk.bst:public-stacks/buildsystem-cmake.bst

depends:
- freedesktop-sdk.bst:public-stacks/runtime-minimal.bst
- freedesktop-sdk.bst:components/cairo.bst

variables:
  cmake-local: >-
    -DWITHOUT_OPENCV=ON
    -DWITHOUT_GAVL=ON

  # Disable SSE 4.1 until upstream fixes the __m128/__m128i type mismatch.
  # https://github.com/dyne/frei0r/issues/228
  # https://github.com/dyne/frei0r/issues/239
  (?):
  - arch == "x86_64":
      local_flags: "-mno-sse4.1"

sources:
- kind: git_repo
  url: github:dyne/frei0r.git
  track: v*
  ref: v3.1.3-0-g32e91405d2ec5e222f75175b36dc4cc7bc0667ef
