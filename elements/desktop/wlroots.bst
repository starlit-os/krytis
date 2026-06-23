# wlroots 0.20.1 — Wayland compositor library.
# Pinned to 0.20.x: noctalia-greeter's meson.build uses
# dependency('wlroots-0.20'), an exact-match pcname, not >=0.20.
# wlroots 0.21+ would require a source edit in noctalia-greeter.
#
# All transitive C sub-deps are in fdsdk — libseat, libinput, libdrm,
# pixman, libdisplay-info, wayland, wayland-protocols, xcb-util-*.
# hwdata: build-depends only (needed for DRM backend configure; overlaps pciutils at runtime).
# Source: https://gitlab.freedesktop.org/wlroots/wlroots/-/archive/0.20.1/wlroots-0.20.1.tar.gz
kind: meson

build-depends:
- freedesktop-sdk.bst:public-stacks/buildsystem-meson.bst
- freedesktop-sdk.bst:components/pkg-config.bst
- freedesktop-sdk.bst:components/wayland.bst
- freedesktop-sdk.bst:components/wayland-protocols.bst
# mesa libdrm.pc lives in %{libdir}/GL/default/lib/pkgconfig, not the default
# pkgconfig path. Must depend on extensions/mesa/libdrm.bst DIRECTLY in
# addition to mesa.bst — the .pc file is in libdrm's runtime split, which
# bst only stages when libdrm.bst is explicitly in the dep graph.
# Without this, meson falls through to the subprojects/libdrm.wrap
# fallback and fails (no network in the sandbox).
- freedesktop-sdk.bst:extensions/mesa/mesa.bst
- freedesktop-sdk.bst:extensions/mesa/libdrm.bst
- freedesktop-sdk.bst:components/libxkbcommon.bst
# hwdata.pc is required by wlroots' DRM backend at configure time, but
# gnome-build-meta:core-deps/hwdata.bst overlaps pciutils (in base-system)
# at runtime. Build-depends only keeps it out of the final image staging.
- gnome-build-meta.bst:core-deps/hwdata.bst
# Vulkan renderer: vulkan-headers for Vulkan API, glslang to compile GLSL
# shaders to SPIR-V at build time. vulkan-icd-loader provides libvulkan.so
# for linking; it is also a runtime dep (wlroots Vulkan backend dlopen's it).
- freedesktop-sdk.bst:components/vulkan-headers.bst
- freedesktop-sdk.bst:components/vulkan-icd-loader.bst
- freedesktop-sdk.bst:components/glslang.bst

depends:
- freedesktop-sdk.bst:public-stacks/runtime-minimal.bst
- freedesktop-sdk.bst:components/wayland.bst
- freedesktop-sdk.bst:components/wayland-protocols.bst
- freedesktop-sdk.bst:components/libinput.bst
- freedesktop-sdk.bst:components/libseat.bst
- freedesktop-sdk.bst:components/libdrm.bst
- freedesktop-sdk.bst:components/pixman.bst
# Use fdsdk's libdisplay-info — gnome-build-meta also ships it and the two
# overlap. niri.bst (already in the image) also uses the fdsdk version, so
# using gnome-build-meta's copy would produce a non-whitelisted overlap at
# oci/krytis/runtime.bst. Same story for hwdata: pciutils (in base-system)
# ships pci.ids which overlaps gnome-build-meta:core-deps/hwdata.bst.
- freedesktop-sdk.bst:components/libdisplay-info.bst
- freedesktop-sdk.bst:components/xorg-lib-xcb.bst
- freedesktop-sdk.bst:components/xcb-util-wm.bst
- freedesktop-sdk.bst:components/xcb-util-image.bst
- freedesktop-sdk.bst:components/xcb-util-keysyms.bst
- freedesktop-sdk.bst:components/xcb-util-renderutil.bst
- freedesktop-sdk.bst:extensions/mesa/mesa.bst
- freedesktop-sdk.bst:components/vulkan-icd-loader.bst

variables:
  # Mesa installs under %{libdir}/GL/default — a non-standard prefix.
  # bst runs each meson stage (configure, build, install) in a separate
  # sh -c, so env exports must be prepended to every stage variable.
  mesa-gl-dir: '%{libdir}/GL/default/lib'
  prepend-mesa-env: |
    export PKG_CONFIG_PATH="%{mesa-gl-dir}/pkgconfig:${PKG_CONFIG_PATH:-}"; export LIBRARY_PATH="%{mesa-gl-dir}:${LIBRARY_PATH:-}"; export LD_LIBRARY_PATH="%{mesa-gl-dir}:${LD_LIBRARY_PATH:-}"
  meson: '%{prepend-mesa-env}; meson setup %{conf-root} %{build-dir} %{meson-args}'
  meson-build: '%{prepend-mesa-env}; ninja -v -j ${JOBS} -C %{build-dir}'
  meson-install: '%{prepend-mesa-env}; env DESTDIR="%{install-root}" meson install -C %{build-dir} --no-rebuild'
  # Valid options for wlroots 0.20.1 (from meson.options):
  # examples, backends (drm/libinput/x11/auto), xwayland, xcb-errors,
  # renderers, allocators, session, color-management, libliftoff.
  # NOT valid: -Dtests (removed since 0.18), -Dlibcap-ng (hard dep),
  # -Dbackends=wayland (wayland is not a wlroots backend choice).
  # Vulkan renderer requires vulkan-headers + vulkan-icd-loader + glslang
  # (glslang compiles GLSL shaders to SPIR-V at build time). Default build
  # omits vulkan — must be listed explicitly in -Drenderers.
  # pixman is NOT a valid -Drenderers value in 0.20.1 (allowed: auto, gles2,
  # vulkan) — pixman renderer is always compiled in unconditionally.
  # gles2 is NOT listed: with auto it was silently skipped because egl.pc is
  # not in the pkgconfig search path in the build sandbox. gles2 also fails
  # at runtime on amdgpu (glvnd can't find radeonsi through fdsdk's non-standard
  # mesa prefix), so omitting it is correct for this image.
  meson-local: >-
    -Dexamples=false
    -Dbackends=libinput,drm,x11
    -Drenderers=vulkan

sources:
- kind: tar
  url: freedesktop_files:wlroots/wlroots/-/archive/0.20.1/wlroots-0.20.1.tar.gz
  ref: e9e699a06492121153ce3a3448b0aa610f3285130754b85fbb58736c931fffec
