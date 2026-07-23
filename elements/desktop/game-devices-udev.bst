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
  ref: ac733ea6babb6623e1ac76eceac9b494255ae312d1e7c3fde011ac50ee99f6c5
