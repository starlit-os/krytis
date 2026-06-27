kind: meson

# Override for components/gstreamer-libav.bst from freedesktop-sdk.
# Rebuilds against extensions/codecs-extra/ffmpeg.bst (H.264/H.265 enabled)
# so avdec_h264 is present and gst-video-thumbnailer can auto-pipeline H.264.
#
# Cross-junction (@) includes are not supported in overrides, so the gstreamer
# source ref and build variables are inlined from fdsdk's gstreamer-source.yml
# and gstreamer-libav.bst. fdsdk patches (patch_queue) are omitted; they are
# internal QA not required for the avdec_h264 fix.
#
# PKG_CONFIG_PATH is extended to cover the codecs-extra prefix so meson can
# locate libavcodec/libavformat at configure time.
#
# Update path: tied to freedesktop-sdk.bst junction ref (git_repo + track: 1.26.*
# means bst source track works). When the junction bumps, update the ref here.
# Closes #184.

sources:
- kind: git_repo
  url: freedesktop:gstreamer/gstreamer.git
  track: 1.26.*
  ref: 1.26.11-0-ge6ee9e63e033b9c8e343ba0bdfa7590ef81449ee

build-depends:
- freedesktop-sdk.bst:public-stacks/buildsystem-meson.bst
- freedesktop-sdk.bst:components/nasm.bst
- freedesktop-sdk.bst:extensions/codecs-extra/ffmpeg.bst

depends:
- freedesktop-sdk.bst:public-stacks/runtime-minimal.bst
- freedesktop-sdk.bst:components/orc.bst
- freedesktop-sdk.bst:components/gstreamer.bst
- freedesktop-sdk.bst:components/gstreamer-plugins-base.bst

environment:
  PKG_CONFIG_PATH: "/usr/lib/%{gcc_triplet}/codecs-extra/lib/pkgconfig:%{libdir}/pkgconfig:%{datadir}/pkgconfig"

variables:
  command-subdir: subprojects/gst-libav
  local_flags: -DTRIPLET='"%{gcc_triplet}"'
