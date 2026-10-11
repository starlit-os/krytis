kind: meson

# Game controller udev rules: Sony, Microsoft, Nintendo, Valve, 8BitDo, Razer,
# HTC (Vive), Logitech, Thrustmaster, VKB, and others. Broader than
# steam-devices.bst (Valve-only); the two coexist without overlap.
# https://codeberg.org/fabiscafe/game-devices-udev

build-depends:
- freedesktop-sdk.bst:public-stacks/buildsystem-meson.bst

depends:
- freedesktop-sdk.bst:public-stacks/runtime-gnu.bst

variables:
  strip-binaries: ""

sources:
- kind: tar
  url: codeberg_files:fabiscafe/game-devices-udev/archive/1.1.tar.gz
  ref: 56527bb4f6f33563c8879f0ba140a9baacf282bf6481b22737b04998dbe7f7af
