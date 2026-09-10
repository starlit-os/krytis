# xdg-desktop-portal-umbriel -- Screencast/Screenshot portal backend for
# desktop/umbriel.bst, from the same upstream team. Net-new packaging surface
# (#774/#775): no existing element anywhere provided this.
#
# Ships two binaries (both meson `install_dir: libexecdir`):
#   xdg-desktop-portal-umbriel -- the portal daemon itself (D-Bus service
#     org.freedesktop.impl.portal.desktop.umbriel, activated by
#     xdg-desktop-portal per usual portal-backend convention).
#   umbriel-share-picker -- optional GTK4 screen/window picker UI, built only
#     when gtk4 (>=4.12) resolves (`required: get_option('picker')`, default
#     `auto`). gnome-build-meta.bst:sdk/gtk.bst is already unconditionally in
#     the image (niri.bst, nautilus, ...), so this builds by default.
#
# Data files (umbriel.portal, umbriel-portals.conf preferring
# `default=umbriel;gtk` for XDG_CURRENT_DESKTOP=Umbriel, both D-Bus/systemd
# service units) are all installed by upstream's own meson.build -- no
# krytis-side portal-routing element needed here, unlike niri's
# config/xdg-portals.bst (niri isn't a portal implementation itself and needed
# a hand-authored routing file; umbriel ships its own valid one).
#
# Does not link wlroots -- captures via raw wayland-protocols staging
# extensions (ext-image-capture-source-v1, ext-image-copy-capture-v1,
# ext-foreign-toplevel-list-v1) plus linux-dmabuf-v1, not wlroots APIs.
#
# gbm.pc/libdrm.pc: same fdsdk mesa GL/default-namespace situation as
# desktop/umbriel.bst and desktop/wlroots.bst -- see the prepend-mesa-env
# block below and docs/skills/bst.md § "fdsdk mesa doesn't expose egl.pc /
# glesv2.pc via pkg-config" (this element needs gbm+libdrm only, not
# egl/glesv2, so components/mesa-headers.bst is not needed here).
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
- gnome-build-meta.bst:sdk/gtk.bst

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
  ref: d7a1bc386c2a6dfaecaa953165f9f373735c9ee0
