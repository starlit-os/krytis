# kmscon — KMS/DRM based virtual console emulator, replacing fbcon on VT2+.
#
# Upstream moved from the Aetf personal fork to the kmscon org
# (github.com/kmscon/kmscon). Meson build. Uses the DRM2D (software-rendered)
# backend, not DRM3D: a text console has no use for GPU-accelerated rendering,
# so the GL path is declined on purpose, not for want of a way to build it.
#
# This comment used to give a second reason — that fdsdk's libglvnd strips
# egl.pc/glesv2.pc, so dependency('egl')/dependency('glesv2') could not
# resolve. That was true when written and is false since
# freedesktop-sdk.bst:components/mesa-headers.bst reinstated those .pc files
# at the standard pkgconfig path. Do not read its absence as an invitation to
# "fix" this by enabling DRM3D/gltex: adding mesa-headers here would buy a
# GPU path this element does not want, for a bigger sandbox and a rebuild.
# See docs/skills/bst.md § *fdsdk mesa doesn't expose `egl.pc` / `glesv2.pc`*.

kind: meson

build-depends:
- freedesktop-sdk.bst:public-stacks/buildsystem-meson.bst
- freedesktop-sdk.bst:components/pkg-config.bst

depends:
- freedesktop-sdk.bst:public-stacks/runtime-gnu.bst
- freedesktop-sdk.bst:components/libdrm.bst
- freedesktop-sdk.bst:components/libxkbcommon.bst
- freedesktop-sdk.bst:components/pango.bst
- gnome-build-meta.bst:core-deps/systemd-libs.bst
- desktop/libtsm.bst

variables:
  meson-local: >-
    -Dtests=false
    -Dvideo_drm2d=enabled
    -Dvideo_drm3d=disabled
    -Dvideo_fbdev=disabled
    -Drenderer_gltex=disabled

config:
  install-commands:
    (>):
    - |
      for unit in kmscon.service 'kmsconvt@.service'; do
        f="%{install-root}%{indep-libdir}/systemd/system/${unit}"
        content=$(cat "$f")
        printf '%s\n' "${content//\/sbin\/agetty//usr/bin/agetty}" > "$f"
      done

sources:
- kind: git_repo
  url: github:kmscon/kmscon.git
  track: v*
  ref: v10.0.3-0-gad9c77bc04f718d0f0d6dfc51291b7d652336429
