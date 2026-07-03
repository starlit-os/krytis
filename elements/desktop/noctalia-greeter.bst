# noctalia-greeter — Quickshell-style login greeter for greetd.
# Pinned to a specific commit on upstream `main` — no release tags exist.
# GitHub's archive/refs/heads/main.tar.gz regenerates on every push;
# always pin to a full commit SHA.
#
# Our PAM_TEXT_INFO cue fix was merged upstream (noctalia-dev/main commit
# 26865dae "always allow empty passwords and surface PAM info messages").
# Pinned to upstream noctalia-dev/noctalia-greeter main, not our fork.
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
- kind: tar
  url: github_files:noctalia-dev/noctalia-greeter/archive/a3265c8c16d3cf338cbb39c7ca718991578e4e26.tar.gz
  ref: 36b5b2562cfbcc46f2525f5aa3a306431eae4d00388252653ce29936df601edf
# Drops the Noctalia brand logo rendered above the login form. Removes the
# texture load in GreeterSurface::initialize() entirely (not just visibility)
# so the logo never occupies layout space and no failed-load warning fires.
- kind: patch
  path: patches/noctalia-greeter/no-brand-logo.patch
