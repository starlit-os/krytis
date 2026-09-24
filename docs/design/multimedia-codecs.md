# Multimedia Codecs

Status: **shipped** as `elements/stacks/codecs.bst` (#35, PR #149), pulled in by
`oci/krytis/stack.bst`. Ported directly from zirconium-hawaii's `stacks/codecs.bst`.

## Elements included

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

Two additions the original port did not have:

- `config/codecs-extra-ldconfig.bst` — drops an `/etc/ld.so.conf.d` entry exposing
  codecs-extra's H.264-enabled `libavcodec.so.61` to the dynamic linker, so
  `gst-libav` registers `avdec_h264` without a rebuild.
- `desktop/vainfo.bst` (#183) — queries the VA-API driver for supported profiles and
  entrypoints; the way to verify hardware decode on a booted image.

Note: `intel-media-driver` is x86_64-only — fine for krytis since we are x86_64_v3 only.
