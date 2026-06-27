kind: meson

# Game controller udev rules: Sony, Microsoft, Nintendo, Valve, 8BitDo, Razer,
# HTC (Vive), Logitech, Thrustmaster, VKB, and others. Broader than
# steam-devices.bst (Valve-only); the two coexist without overlap.
# https://codeberg.org/fabiscafe/game-devices-udev

build-depends:
- freedesktop-sdk.bst:public-stacks/buildsystem-meson.bst

depends:
- freedesktop-sdk.bst:public-stacks/runtime-minimal.bst

variables:
  strip-binaries: ""

sources:
- kind: tar
  url: codeberg_files:fabiscafe/game-devices-udev/archive/1.0.tar.gz
  ref: 642315c110f427d0765abe66369f3080604c3fb7243c07d1aa77303b31f6dc6d
