# Cage 0.3.0 — wlroots kiosk compositor, used by noctalia-greeter-session.
# Upstream moved from sr.ht/Hjdskes/cage to cage-kiosk/cage (GitHub) as of
# 2026-04-11. Use the cage-kiosk org URL.
kind: meson

build-depends:
- freedesktop-sdk.bst:public-stacks/buildsystem-meson.bst
- freedesktop-sdk.bst:components/pkg-config.bst
- freedesktop-sdk.bst:components/wayland.bst
- freedesktop-sdk.bst:components/wayland-protocols.bst
- freedesktop-sdk.bst:extensions/mesa/mesa.bst
- freedesktop-sdk.bst:extensions/mesa/libdrm.bst

depends:
- freedesktop-sdk.bst:public-stacks/runtime-minimal.bst
- freedesktop-sdk.bst:components/wayland.bst
- freedesktop-sdk.bst:components/libxkbcommon.bst
- freedesktop-sdk.bst:extensions/mesa/mesa.bst
- desktop/wlroots.bst

variables:
  mesa-gl-dir: '%{libdir}/GL/default/lib'
  prepend-mesa-env: |
    export PKG_CONFIG_PATH="%{mesa-gl-dir}/pkgconfig:${PKG_CONFIG_PATH:-}"; export LIBRARY_PATH="%{mesa-gl-dir}:${LIBRARY_PATH:-}"; export LD_LIBRARY_PATH="%{mesa-gl-dir}:${LD_LIBRARY_PATH:-}"
  meson: '%{prepend-mesa-env}; meson setup %{conf-root} %{build-dir} %{meson-args}'
  meson-build: '%{prepend-mesa-env}; ninja -v -j ${JOBS} -C %{build-dir}'
  meson-install: '%{prepend-mesa-env}; env DESTDIR="%{install-root}" meson install -C %{build-dir} --no-rebuild'
  meson-local: >-
    -Dman-pages=disabled

sources:
- kind: tar
  url: github_files:cage-kiosk/cage/releases/download/v0.3.0/cage-0.3.0.tar.gz
  ref: cd2510f83bef3e08e660d99492ca7761b218ecb53ee01cdbbeee3d6aabc7734e
