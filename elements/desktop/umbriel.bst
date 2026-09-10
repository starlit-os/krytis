# Umbriel -- wlroots-based Wayland compositor built by the noctalia-dev team,
# additive/opt-in alongside desktop/niri.bst (design decision: #774, tracked
# implementation: #775). Ships as a second selectable greetd session; niri
# remains the default.
#
# umbrielfx (Umbriel's own hard fork of SceneFX -- scene graph + GLES2
# renderer) builds in-tree via `subdir('umbrielfx')` in meson.build as a
# static archive. No external scenefx package is involved, no cargo-style
# vendoring step (unlike niri.bst).
#
# jemalloc: optional upstream dep (`-Djemalloc=<auto|enabled|disabled>`), not
# packaged anywhere in the fdsdk/gnome-build-meta closure. Disabled explicitly
# -- same call as desktop/noctalia.bst's `-Djemalloc=disabled`.
# tests: disabled explicitly (`-Dtests=disabled`) -- we don't ship or run
# umbrielfx's unit tests / harness clients, same reasoning as
# desktop/noctalia.bst's `-Dtests=disabled`.
#
# egl.pc / glesv2.pc: umbrielfx/meson.build has HARD, non-optional
# `dependency('egl')` / `dependency('gbm')` / `dependency('glesv2')` calls --
# unlike noctalia-greeter.bst's compositor (which falls back to
# `dependency('epoxy')` when egl/glesv2 aren't found via pkg-config), umbriel
# has no epoxy fallback anywhere in its build. freedesktop-sdk's own mesa
# build does NOT expose egl.pc/glesv2.pc (components/libglvnd.bst deliberately
# rm's them; see docs/skills/bst.md § "fdsdk mesa doesn't expose egl.pc /
# glesv2.pc via pkg-config") -- but freedesktop-sdk.bst:components/
# mesa-headers.bst exists specifically to regenerate them (standard
# %{libdir}/pkgconfig, not mesa's namespaced GL/default split) plus the
# matching EGL/GLES2/KHR headers. It's normally only pulled in as a
# build-depends of other elements (e.g. components/libepoxy.bst), which does
# NOT propagate here (build-depends never does), so it must be declared
# directly. The actual runtime libEGL.so.1/libGLESv2.so.2 come from
# components/libglvnd.bst separately (mesa-headers.bst ships no .so of its
# own).
#
# gbm.pc / libdrm.pc live in mesa's non-standard GL/default path; the
# prepend-mesa-env pattern (same as desktop/wlroots.bst,
# desktop/noctalia-greeter.bst) handles PKG_CONFIG_PATH for all three meson
# stages. extensions/mesa/libdrm.bst is required in addition to
# extensions/mesa/mesa.bst for the same reason documented in
# desktop/wlroots.bst: mesa's libdrm.pc lives in libdrm's runtime split,
# which BuildStream only stages when extensions/mesa/libdrm.bst is
# explicitly in this element's own dependency graph.
#
# wlroots must be built with the gles2 renderer for this element to compile at
# all: umbrielfx includes <wlr/render/egl.h>, and wlroots'
# include/meson.build excludes render/egl.h + render/gles2.h from install
# unless the gles2-renderer feature is on. desktop/wlroots.bst therefore uses
# -Drenderers=gles2,vulkan (#775); see docs/skills/desktop.md
# § "wlroots renderers" for the pkg-config ripple that flip caused in every
# other wlroots consumer.
#
# nlohmann-json: freedesktop-sdk 26.08 dropped components/nlohmann-json.bst
# (see desktop/nlohmann-json.bst) -- use the krytis-vendored element, same as
# desktop/noctalia.bst / desktop/noctalia-greeter.bst.
#
# libinput (>=1.23), pixman (>=0.43.0), wayland-server (>=1.24): resolve
# transitively through desktop/wlroots.bst's own `depends:` (BuildStream
# stages `depends` at build time too, recursively) -- no explicit entry
# needed here. xkbcommon and cairo/pangocairo do NOT resolve transitively
# (wlroots.bst only build-depends on libxkbcommon, and doesn't touch
# cairo/pango at all), so they're declared directly below, matching
# desktop/noctalia-greeter.bst's identical pattern.
#
# libudev (optional, native [drm] GPU-exclusion policy) and lcms2 (optional,
# client ICC profile support in umbrielfx) are both upstream `required: false`
# deps -- included anyway since both are already-packaged, low-cost, and
# meaningfully improve on the "silently skip the feature" fallback.
#
# xwayland-satellite: a *runtime* PATH dependency (`general.xwayland = true`
# in config), not a build-time link dependency -- umbriel execs it, doesn't
# link it. Already unconditionally shipped by stacks/desktop.bst (shared with
# niri), so not re-declared here.
#
# Update-path gate: upstream noctalia-dev/umbriel has no tags/releases yet
# (checked as of 2026-09; see #774/#775). Uses kind: git_repo,
# track: refs/heads/main -- same branch-tracking pattern as desktop/stb.bst.
# Revisit to `track: v*` once upstream cuts a first tagged release.
kind: meson

build-depends:
- freedesktop-sdk.bst:public-stacks/buildsystem-meson.bst
- freedesktop-sdk.bst:components/pkg-config.bst
- freedesktop-sdk.bst:components/git.bst
- freedesktop-sdk.bst:components/wayland.bst
- freedesktop-sdk.bst:components/wayland-protocols.bst
- freedesktop-sdk.bst:extensions/mesa/mesa.bst
- freedesktop-sdk.bst:extensions/mesa/libdrm.bst
- freedesktop-sdk.bst:components/mesa-headers.bst
- desktop/nlohmann-json.bst

depends:
- freedesktop-sdk.bst:public-stacks/runtime-gnu.bst
- desktop/wlroots.bst
- freedesktop-sdk.bst:components/wayland.bst
- freedesktop-sdk.bst:components/wayland-protocols.bst
- freedesktop-sdk.bst:components/libxkbcommon.bst
- freedesktop-sdk.bst:components/cairo.bst
- freedesktop-sdk.bst:components/pango.bst
- freedesktop-sdk.bst:components/tomlplusplus.bst
- freedesktop-sdk.bst:components/libglvnd.bst
- freedesktop-sdk.bst:components/systemd-libs.bst
- freedesktop-sdk.bst:components/lcms.bst
- freedesktop-sdk.bst:extensions/mesa/mesa.bst

variables:
  mesa-gl-dir: '%{libdir}/GL/default/lib'
  prepend-mesa-env: |
    export PKG_CONFIG_PATH="%{mesa-gl-dir}/pkgconfig:${PKG_CONFIG_PATH:-}"; export LIBRARY_PATH="%{mesa-gl-dir}:${LIBRARY_PATH:-}"; export LD_LIBRARY_PATH="%{mesa-gl-dir}:${LD_LIBRARY_PATH:-}"
  meson: '%{prepend-mesa-env}; meson setup %{conf-root} %{build-dir} %{meson-args}'
  meson-build: '%{prepend-mesa-env}; ninja -v -j ${JOBS} -C %{build-dir}'
  meson-install: '%{prepend-mesa-env}; env DESTDIR="%{install-root}" meson install -C %{build-dir} --no-rebuild'
  meson-local: >-
    -Djemalloc=disabled
    -Dtests=disabled

sources:
- kind: git_repo
  url: github:noctalia-dev/umbriel.git
  track: refs/heads/main
  ref: 3efacb3640a9859c7711e7ddd0b157c143b45f9c
