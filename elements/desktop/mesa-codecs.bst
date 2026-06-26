kind: manual

# VA-API video decoder override for AMD GPUs. Closes #158.
#
# fdsdk base mesa.bst builds with video_codecs: all_free — H.264 and other
# patent-encumbered codecs are absent from radeonsi_drv_video.so. mesa-extra.bst
# builds with video_codecs: all but cannot be added alongside mesa.bst as a
# runtime dep (BST fatal-warnings: overlaps — both provide the full mesa tree).
#
# This element uses mesa-extra.bst as a build-only dep, extracts the gallium
# VA-API video driver files, and installs them with overlap-whitelist so they
# replace the all_free versions from mesa.bst in the composed image.
#
# Update path: tied to freedesktop-sdk.bst junction ref — no separate tracking.

build-depends:
  - freedesktop-sdk.bst:extensions/mesa/mesa-extra.bst

variables:
  strip-binaries: ''
  dri-dir: "%{libdir}/GL/default/lib/dri"

config:
  strip-commands:
    - ':'

  install-commands:
    - |
      for f in "%{dri-dir}"/*_drv_video.so; do
        [ -f "$f" ] || continue
        install -Dm755 "$f" "%{install-root}$f"
      done

public:
  bst:
    overlap-whitelist:
      - '/usr/lib/x86_64-linux-gnu/GL/default/lib/dri/*_drv_video.so'
