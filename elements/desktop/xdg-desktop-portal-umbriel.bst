# xdg-desktop-portal-umbriel -- ScreenCast/Screenshot/InputCapture/
# GlobalShortcuts portal backend for desktop/umbriel.bst, from the same
# upstream team. GlobalShortcuts talks to the compositor over the private
# umbriel-global-shortcuts-v1 protocol, so this pin and desktop/umbriel.bst's
# must both include it (krytis#1055; docs/skills/desktop.md § xdg-desktop-portal
# routing). Net-new packaging surface (#774/#775): no existing element
# anywhere provided this.
#
# Ships two binaries (both meson `install_dir: libexecdir`):
#   xdg-desktop-portal-umbriel -- the portal daemon itself (D-Bus service
#     org.freedesktop.impl.portal.desktop.umbriel, activated by
#     xdg-desktop-portal per usual portal-backend convention).
#   umbriel-share-picker -- screen/window picker UI. Since upstream ed91d04
#     ("replace GTK by noctalia-ui lib") it is built on an in-tree static copy
#     of Noctalia's UI library (lib/, the same one desktop/luciole.bst builds),
#     not GTK4, and `picker` is a boolean defaulting to true, so a missing
#     dependency fails meson setup instead of silently skipping the picker.
#     lib/meson.build needs egl/glesv2, wayland-egl, freetype2, fontconfig,
#     cairo-ft, pango/pangocairo/pangoft2, harfbuzz, xkbcommon, glib and the
#     stb/stb_image_resize2.h header; the depends below mirror luciole.bst's.
#     egl/glesv2 come from components/mesa-headers.bst: without it lib/'s
#     egl -> wayland-egl -> epoxy fallback chain would pick epoxy, which the
#     sources (direct <EGL/egl.h>/<GLES2/gl2.h> calls) can't use -- see
#     luciole.bst's header and docs/skills/bst.md § "fdsdk mesa doesn't
#     expose egl.pc / glesv2.pc". The codec pack (noctalia_ui_build_codecs)
#     is not enabled by this project, so no libjxl/libwebp/librsvg.
#
# Data files (umbriel.portal, umbriel-portals.conf preferring
# `default=umbriel;gtk` for XDG_CURRENT_DESKTOP=Umbriel, both D-Bus/systemd
# service units) are all installed by upstream's own meson.build. krytis's
# routing is config/xdg-desktop-portal-routing.bst's /etc/xdg file, not edits
# here; its default= shadows this umbriel-portals.conf for every interface
# umbriel, gnome or gtk implements (krytis#1029).
#
# Does not link wlroots -- captures via raw wayland-protocols staging
# extensions (ext-image-capture-source-v1, ext-image-copy-capture-v1,
# ext-foreign-toplevel-list-v1) plus linux-dmabuf-v1, not wlroots APIs.
#
# gbm.pc/libdrm.pc: same fdsdk mesa GL/default-namespace situation as
# desktop/umbriel.bst and desktop/wlroots.bst -- see the prepend-mesa-env
# block below and docs/skills/bst.md § "fdsdk mesa doesn't expose egl.pc /
# glesv2.pc". The daemon needs gbm+libdrm only; egl/glesv2 are the picker's
# (above).
#
# nlohmann-json: krytis-vendored element, not freedesktop-sdk's own (dropped
# in fdsdk 26.08) -- see desktop/nlohmann-json.bst.
#
# Update-path gate: upstream noctalia-dev/xdg-desktop-portal-umbriel has no
# tags/releases yet (checked as of 2026-09; independently from
# noctalia-dev/umbriel -- a separate, younger repo). Uses kind: git_repo,
# track: refs/heads/main, same as desktop/umbriel.bst and desktop/stb.bst.
# Revisit to `track: v*` once upstream cuts a first tagged release.
kind: meson

build-depends:
- freedesktop-sdk.bst:public-stacks/buildsystem-meson.bst
- freedesktop-sdk.bst:components/pkg-config.bst
- freedesktop-sdk.bst:components/wayland.bst
- freedesktop-sdk.bst:components/wayland-protocols.bst
- freedesktop-sdk.bst:components/glib.bst
- freedesktop-sdk.bst:extensions/mesa/mesa.bst
- freedesktop-sdk.bst:extensions/mesa/libdrm.bst
- freedesktop-sdk.bst:components/mesa-headers.bst
# Header-only: lib/meson.build has_header()-checks stb/stb_image_resize2.h.
- desktop/stb.bst
- desktop/nlohmann-json.bst

depends:
- freedesktop-sdk.bst:public-stacks/runtime-gnu.bst
- desktop/sdbus-cpp.bst
- freedesktop-sdk.bst:components/pipewire.bst
- freedesktop-sdk.bst:components/wayland.bst
- freedesktop-sdk.bst:components/wayland-protocols.bst
- freedesktop-sdk.bst:components/cairo.bst
- freedesktop-sdk.bst:components/tomlplusplus.bst
- freedesktop-sdk.bst:extensions/mesa/mesa.bst
- freedesktop-sdk.bst:components/libglvnd.bst
- freedesktop-sdk.bst:components/libxkbcommon.bst
- freedesktop-sdk.bst:components/freetype.bst
- freedesktop-sdk.bst:components/fontconfig.bst
- freedesktop-sdk.bst:components/harfbuzz.bst
- freedesktop-sdk.bst:components/pango.bst
- freedesktop-sdk.bst:components/glib.bst

variables:
  mesa-gl-dir: '%{libdir}/GL/default/lib'
  prepend-mesa-env: |
    export PKG_CONFIG_PATH="%{mesa-gl-dir}/pkgconfig:${PKG_CONFIG_PATH:-}"; export LIBRARY_PATH="%{mesa-gl-dir}:${LIBRARY_PATH:-}"; export LD_LIBRARY_PATH="%{mesa-gl-dir}:${LD_LIBRARY_PATH:-}"
  meson: '%{prepend-mesa-env}; meson setup %{conf-root} %{build-dir} %{meson-args}'
  meson-build: '%{prepend-mesa-env}; ninja -v -j ${JOBS} -C %{build-dir}'
  meson-install: '%{prepend-mesa-env}; env DESTDIR="%{install-root}" meson install -C %{build-dir} --no-rebuild'

sources:
- kind: git_repo
  url: github:noctalia-dev/xdg-desktop-portal-umbriel.git
  track: refs/heads/main
  ref: e81fb92f6d7bda38ab249d391d1ea48469047fff
