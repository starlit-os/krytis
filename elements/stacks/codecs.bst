kind: stack

# Multimedia codec stack — ported from zirconium-hawaii stacks/codecs.bst.
# All elements come from fdsdk / gnome-build-meta; no new elements needed.
# intel-media-driver is x86_64-only; krytis is x86_64_v3-only so this is fine.
# Closes #35. Part of #59.
depends:
  # ── FFmpeg ─────────────────────────────────────────────────────────────
  - freedesktop-sdk.bst:components/ffmpeg.bst

  # ── GStreamer core + plugins ────────────────────────────────────────────
  - freedesktop-sdk.bst:components/gstreamer.bst
  - freedesktop-sdk.bst:components/gstreamer-libav.bst
  - freedesktop-sdk.bst:components/gstreamer-plugins-bad.bst
  - freedesktop-sdk.bst:components/gstreamer-plugins-base.bst
  - freedesktop-sdk.bst:components/gstreamer-plugins-good.bst
  - freedesktop-sdk.bst:components/gstreamer-plugins-rs.bst
  - freedesktop-sdk.bst:components/gstreamer-plugins-ugly.bst

  # ── SDL3 ───────────────────────────────────────────────────────────────
  - freedesktop-sdk.bst:components/sdl3.bst

  # ── Codec extras (patent-encumbered; fdsdk extensions/ namespace) ───────
  - freedesktop-sdk.bst:extensions/codecs-extra/ffmpeg.bst
  - freedesktop-sdk.bst:extensions/codecs-extra/gstreamer-plugins-ugly-x264.bst
  - freedesktop-sdk.bst:extensions/codecs-extra/libheif.bst

  # ── VAAPI — Intel hardware video acceleration ───────────────────────────
  - freedesktop-sdk.bst:extensions/platform-vaapi-intel/intel-media-driver.bst

  # ── Thumbnailing ────────────────────────────────────────────────────────
  - gnome-build-meta.bst:core/gst-thumbnailers.bst
