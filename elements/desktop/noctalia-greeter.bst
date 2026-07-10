# noctalia-greeter — Quickshell-style login greeter for greetd.
# Upstream noctalia-dev/noctalia-greeter. Releases tagged v* (v1.0.0 latest
# as of this pin). git_repo + track: v* lets bst source track follow tags.
#
# The greeter runs inside Cage (kiosk wlroots compositor) via the
# noctalia-greeter-session wrapper script that greetd calls.
# gbm.pc and libdrm.pc live in mesa's non-standard GL/default path;
# the prepend-mesa-env pattern handles PKG_CONFIG_PATH for all three
# meson stages.
kind: meson

build-depends:
- freedesktop-sdk.bst:public-stacks/buildsystem-meson.bst
- freedesktop-sdk.bst:components/pkg-config.bst
- freedesktop-sdk.bst:components/wayland.bst
- freedesktop-sdk.bst:components/wayland-protocols.bst
- freedesktop-sdk.bst:components/scdoc.bst
- freedesktop-sdk.bst:extensions/mesa/mesa.bst
- freedesktop-sdk.bst:extensions/mesa/libdrm.bst

depends:
- freedesktop-sdk.bst:public-stacks/runtime-minimal.bst
- freedesktop-sdk.bst:components/wayland.bst
- freedesktop-sdk.bst:components/wayland-protocols.bst
- freedesktop-sdk.bst:components/cairo.bst
- freedesktop-sdk.bst:components/pango.bst
- freedesktop-sdk.bst:components/freetype.bst
- freedesktop-sdk.bst:components/fontconfig.bst
- freedesktop-sdk.bst:components/libwebp.bst
- freedesktop-sdk.bst:components/libxkbcommon.bst
- freedesktop-sdk.bst:components/librsvg.bst
- freedesktop-sdk.bst:components/glib.bst
- freedesktop-sdk.bst:components/libepoxy.bst
- gnome-build-meta.bst:sdk/librsvg.bst
- freedesktop-sdk.bst:extensions/mesa/mesa.bst
- desktop/wlroots.bst

variables:
  mesa-gl-dir: '%{libdir}/GL/default/lib'
  prepend-mesa-env: |
    export PKG_CONFIG_PATH="%{mesa-gl-dir}/pkgconfig:${PKG_CONFIG_PATH:-}"; export LIBRARY_PATH="%{mesa-gl-dir}:${LIBRARY_PATH:-}"; export LD_LIBRARY_PATH="%{mesa-gl-dir}:${LD_LIBRARY_PATH:-}"
  meson: '%{prepend-mesa-env}; meson setup %{conf-root} %{build-dir} %{meson-args}'
  meson-build: '%{prepend-mesa-env}; ninja -v -j ${JOBS} -C %{build-dir}'
  meson-install: '%{prepend-mesa-env}; env DESTDIR="%{install-root}" meson install -C %{build-dir} --no-rebuild'

sources:
- kind: git_repo
  url: github:noctalia-dev/noctalia-greeter.git
  track: v*
  ref: v1.0.0-0-g68fa4a04122c0c9ded77072eb3a04464ed635f6b
