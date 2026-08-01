# Deferred: Multimedia Codecs

Zirconium-hawaii has everything we need in `stacks/codecs.bst`. Port it directly as
`stacks/codecs.bst` and add it to `oci/krytis/stack.bst`.

## Elements to include

All from fdsdk / gnome-build-meta — no new elements to write, just a stack:

```yaml
kind: stack

depends:
  - freedesktop-sdk.bst:components/ffmpeg.bst
  - freedesktop-sdk.bst:components/gstreamer.bst
  - freedesktop-sdk.bst:components/gstreamer-libav.bst
  - freedesktop-sdk.bst:components/gstreamer-plugins-bad.bst
  - freedesktop-sdk.bst:components/gstreamer-plugins-base.bst
  - freedesktop-sdk.bst:components/gstreamer-plugins-good.bst
  - freedesktop-sdk.bst:components/gstreamer-plugins-rs.bst
  - freedesktop-sdk.bst:components/gstreamer-plugins-ugly.bst
  - freedesktop-sdk.bst:components/sdl3.bst
  - freedesktop-sdk.bst:extensions/codecs-extra/ffmpeg.bst
  - freedesktop-sdk.bst:extensions/codecs-extra/gstreamer-plugins-ugly-x264.bst
  - freedesktop-sdk.bst:extensions/codecs-extra/libheif.bst
  - freedesktop-sdk.bst:extensions/platform-vaapi-intel/intel-media-driver.bst
  - gnome-build-meta.bst:core/gst-thumbnailers.bst
```

Note: `intel-media-driver` is x86_64-only — fine for krytis since we are x86_64_v3 only.
