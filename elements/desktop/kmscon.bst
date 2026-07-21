# kmscon — KMS/DRM based virtual console emulator, replacing fbcon on VT2+.
#
# Upstream moved from the Aetf personal fork to the kmscon org
# (github.com/kmscon/kmscon). Meson build. Uses the DRM2D (software-rendered)
# backend, not DRM3D — fdsdk's libglvnd strips egl.pc/glesv2.pc from the
# standard pkgconfig path and mesa's own GL/default split doesn't reinstate
# them, so dependency('egl')/dependency('glesv2') can't resolve. A text
# console has no need for GPU-accelerated rendering anyway.

kind: meson

build-depends:
- freedesktop-sdk.bst:public-stacks/buildsystem-meson.bst
- freedesktop-sdk.bst:components/pkg-config.bst

depends:
- freedesktop-sdk.bst:public-stacks/runtime-minimal.bst
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
  ref: v10.0.1-0-gc9d0e23336c6bb7645a1f5f48a4a82f1d5a589d9
