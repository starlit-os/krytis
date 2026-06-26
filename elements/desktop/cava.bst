# cava — Console-based Audio Visualizer for ALSA/PipeWire.
# Built with autotools; git_repo source requires autoreconf before configure.
# Audio backends enabled: PipeWire (primary, matches stack) + ALSA (fallback).
# Output: terminal escape codes (default) — ncurses and SDL2 not present in fdsdk.
kind: autotools

build-depends:
- freedesktop-sdk.bst:public-stacks/buildsystem-autotools.bst
- freedesktop-sdk.bst:components/pkg-config.bst
- freedesktop-sdk.bst:components/fftw.bst
- freedesktop-sdk.bst:components/alsa-lib.bst
- freedesktop-sdk.bst:components/pipewire.bst

depends:
- freedesktop-sdk.bst:public-stacks/runtime-minimal.bst
- freedesktop-sdk.bst:components/fftw.bst
- freedesktop-sdk.bst:components/alsa-lib.bst
- freedesktop-sdk.bst:components/pipewire.bst

config:
  configure-commands:
  - autoreconf -fiv
  - |
    %{conf-cmd} %{conf-global} %{conf-local}

sources:
- kind: git_repo
  url: github:karlstav/cava.git
  track: '[0-9]*'
  ref: 1.0.0-0-g15f89867908fa66baaaec8d4b9a2d684a329a0fb
