kind: manual

# Adds /usr/lib/%{gcc_triplet}/codecs-extra/lib to the dynamic linker search.
#
# fdsdk's codecs-extra/ffmpeg installs to that non-standard prefix; base ffmpeg
# is at the standard /usr/lib/%{gcc_triplet}/ path. Without this entry, only the
# base libavcodec.so.61 (H.264 decode disabled) is visible to the linker, so
# gst-libav never registers avdec_h264.
#
# With this entry, codecs-extra/libavcodec.so.61 (H.264 enabled) takes
# precedence in ldconfig scan order, so gst-libav discovers avdec_h264 at
# plugin-init time via av_codec_iterate() — no gst-libav rebuild required.
# avdec_h264 provides a software fallback when VA-API/Vulkan H.264 decode
# fails (e.g. gst-video-thumbnailer invoked without a render context).
# Closes #184.

build-depends:
- freedesktop-sdk.bst:public-stacks/runtime-minimal.bst

variables:
  strip-binaries: ''

config:
  install-commands:
  - |
    install -Dm644 /dev/stdin \
        "%{install-root}/etc/ld.so.conf.d/codecs-extra.conf" <<'EOF'
    /usr/lib/%{gcc_triplet}/codecs-extra/lib
    EOF
  - "%{install-extra}"
