kind: cmake

build-depends:
- freedesktop-sdk.bst:public-stacks/buildsystem-cmake.bst

depends:
- freedesktop-sdk.bst:public-stacks/runtime-minimal.bst

# Markdown parser library (github.com/mity/md4c). Required by noctalia since
# v5.0.0-beta2 (markdown rendering); not shipped by the freedesktop-sdk or
# gnome-build-meta junctions, so built here. Releases tagged release-X.Y.Z.
sources:
- kind: git_repo
  url: github:mity/md4c.git
  track: release-*
  ref: release-0.5.3-0-g472c417005c2c71b8617de4f7b8d6b30411d78f4

variables:
  cmake-local: >-
    -DBUILD_MD2HTML_EXECUTABLE=OFF
