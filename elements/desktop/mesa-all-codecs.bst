kind: meson

# Mesa with video_codecs: all, used to override extensions/mesa/mesa.bst in the
# freedesktop-sdk junction (see elements/freedesktop-sdk.bst overrides).
#
# Replaces the all_free base mesa across the entire image, enabling H.264/H.265
# VA-API hardware decode on AMD (radeonsi), Intel (i965), and nouveau GPUs.
# Using a junction override (rather than a second mesa dep) keeps exactly one
# mesa artifact in the image — no overlap-whitelist juggling needed.
#
# Sources and build config mirror freedesktop-sdk mesa-extra.bst exactly so BST
# can reuse the remote-cached artifact when the resolved configuration matches.
#
# Update path: tied to freedesktop-sdk.bst junction ref — no separate tracking.
# When the junction bumps, update the git ref and crate refs here to match.
# Closes #158.

sources:
- kind: git_repo
  url: freedesktop:mesa/mesa.git
  track: mesa-*
  exclude:
  - '*rc*'
  - '*branchpoint*'
  ref: mesa-26.0.8-0-g60e95b787857afbc9a00b693b91c0d9c8923a430
# Rust dependencies (must match fdsdk mesa-sources.yml exactly for cache reuse):
- kind: tar
  directory: subprojects/packagecache/syn-2.0.87
  url: crates:crates/syn/syn-2.0.87.crate
  ref: 25aa4ce346d03a6dcd68dd8b4010bcb74e54e62c90c573f394c46eae99aba32d
- kind: tar
  directory: subprojects/packagecache/unicode-ident-1.0.12
  url: crates:crates/unicode-ident/unicode-ident-1.0.12.crate
  ref: 3354b9ac3fae1ff6755cb6db53683adb661634f67557942dea4facebec0fee4b
- kind: tar
  directory: subprojects/packagecache/proc-macro2-1.0.86
  url: crates:crates/proc-macro2/proc-macro2-1.0.86.crate
  ref: 5e719e8df665df0d1c8fbfd238015744736151d4445ec0836b8e628aae103b77
- kind: tar
  directory: subprojects/packagecache/quote-1.0.35
  url: crates:crates/quote/quote-1.0.35.crate
  ref: 291ec9ab5efd934aaf503a6466c5d5251535d108ee747472c3977cc5acc868ef
- kind: tar
  directory: subprojects/packagecache/paste-1.0.14
  url: crates:crates/paste/paste-1.0.14.crate
  ref: de3145af08024dea9fa9914f381a17b8fc6034dfb00f3a84013f7ff43f29ed4c
- kind: tar
  directory: subprojects/packagecache/roxmltree-0.20.0
  url: crates:crates/roxmltree/roxmltree-0.20.0.crate
  ref: 6c20b6793b5c2fa6553b250154b78d6d0db37e72700ae35fad9387a46f487c97
- kind: tar
  directory: subprojects/packagecache/equivalent-1.0.1
  url: crates:crates/equivalent/equivalent-1.0.1.crate
  ref: 5443807d6dff69373d433ab9ef5378ad8df50ca6298caf15de6e52e24aaf54d5
- kind: tar
  directory: subprojects/packagecache/hashbrown-0.14.1
  url: crates:crates/hashbrown/hashbrown-0.14.1.crate
  ref: 7dfda62a12f55daeae5015f81b0baea145391cb4520f86c248fc615d72640d12
- kind: tar
  directory: subprojects/packagecache/indexmap-2.2.6
  url: crates:crates/indexmap/indexmap-2.2.6.crate
  ref: 168fb715dda47215e360912c096649d23d58bf392ac62f73919e831745e40f26
- kind: tar
  directory: subprojects/packagecache/once_cell-1.8.0
  url: crates:crates/once_cell/once_cell-1.8.0.crate
  ref: 692fcb63b64b1758029e0a96ee63e049ce8c5948587f2f7208df04625e5f6b56
- kind: tar
  directory: subprojects/packagecache/pest-2.7.11
  url: crates:crates/pest/pest-2.7.11.crate
  ref: cd53dff83f26735fdc1ca837098ccf133605d794cdae66acfc2bfac3ec809d95
- kind: tar
  directory: subprojects/packagecache/pest_derive-2.7.11
  url: crates:crates/pest_derive/pest_derive-2.7.11.crate
  ref: 2a548d2beca6773b1c244554d36fcf8548a8a58e74156968211567250e48e49a
- kind: tar
  directory: subprojects/packagecache/pest_generator-2.7.11
  url: crates:crates/pest_generator/pest_generator-2.7.11.crate
  ref: 3c93a82e8d145725dcbaf44e5ea887c8a869efdcc28706df2d08c69e17077183
- kind: tar
  directory: subprojects/packagecache/pest_meta-2.7.11
  url: crates:crates/pest_meta/pest_meta-2.7.11.crate
  ref: a941429fea7e08bedec25e4f6785b6ffaacc6b755da98df5ef3e7dcf4a124c4f
- kind: tar
  directory: subprojects/packagecache/ucd-trie-0.1.6
  url: crates:crates/ucd-trie/ucd-trie-0.1.6.crate
  ref: ed646292ffc8188ef8ea4d1e0e0150fb15a5c2e12ad9b8fc191ae7a8a7f3c4b9
- kind: tar
  directory: subprojects/packagecache/rustc-hash-2.1.1
  url: crates:crates/rustc-hash/rustc-hash-2.1.1.crate
  ref: 357703d41365b4b27c590e3ed91eabb1b663f07c4c084095e60cbed4362dff0d

build-depends:
  - freedesktop-sdk.bst:components/bison.bst
  - freedesktop-sdk.bst:components/flex.bst
  - freedesktop-sdk.bst:components/llvm.bst
  - freedesktop-sdk.bst:components/python3.bst
  - freedesktop-sdk.bst:components/python3-mako.bst
  - freedesktop-sdk.bst:components/python3-packaging.bst
  - freedesktop-sdk.bst:components/python3-ply.bst
  - freedesktop-sdk.bst:components/python3-pycparser.bst
  - freedesktop-sdk.bst:components/python3-pyyaml.bst
  - freedesktop-sdk.bst:components/rust.bst
  - freedesktop-sdk.bst:components/rust-bindgen.bst
  - freedesktop-sdk.bst:components/rust-cbindgen.bst
  - freedesktop-sdk.bst:components/spirv-llvm-translator.bst
  - freedesktop-sdk.bst:components/spirv-tools.bst
  - freedesktop-sdk.bst:components/vulkan-headers.bst
  - freedesktop-sdk.bst:components/wayland-protocols.bst
  - freedesktop-sdk.bst:components/glslang.bst
  - freedesktop-sdk.bst:public-stacks/buildsystem-meson.bst

depends:
  - freedesktop-sdk.bst:public-stacks/runtime-minimal.bst
  - freedesktop-sdk.bst:components/libdrm.bst
  - freedesktop-sdk.bst:components/libva.bst
  - freedesktop-sdk.bst:components/opencl.bst
  - freedesktop-sdk.bst:components/xorg-lib-x11.bst
  - freedesktop-sdk.bst:components/xorg-lib-xfixes.bst
  - freedesktop-sdk.bst:components/xorg-lib-xrandr.bst
  - freedesktop-sdk.bst:components/xorg-lib-xshmfence.bst
  - freedesktop-sdk.bst:components/xorg-lib-xxf86vm.bst
  - freedesktop-sdk.bst:components/vulkan-icd-loader.bst
  - freedesktop-sdk.bst:components/wayland.bst
  - freedesktop-sdk.bst:components/libglvnd.bst
  - freedesktop-sdk.bst:components/libvdpau.bst
  - freedesktop-sdk.bst:components/libpng.bst
  - freedesktop-sdk.bst:components/libunwind.bst
  - freedesktop-sdk.bst:components/zstd.bst
  - freedesktop-sdk.bst:extensions/mesa/libclc.bst
  - freedesktop-sdk.bst:extensions/mesa/libdrm.bst
  - freedesktop-sdk.bst:extensions/mesa/llvm.bst

environment:
  PKG_CONFIG_PATH: "%{libdir}/pkgconfig:%{datadir}/pkgconfig"
  CXXFLAGS: "%{target_flags} -std=gnu++17"

variables:
  # mesa extension prefix — overrides the standard /usr prefix
  prefix: "/usr/lib/%{gcc_triplet}/GL/default"
  lib: "lib"
  debugdir: "/usr/lib/debug"
  debugdatadir: "%{debugdir}%{prefix}"

  # x86_64 resolved values (krytis targets x86_64_v3 only)
  intel-rt: "enabled"
  gallium_drivers: "iris,crocus,nouveau,r300,r600,radeonsi,svga,softpipe,llvmpipe,virgl,zink,i915"
  vulkan_drivers: "amd,intel,intel_hasvk,swrast,virtio,nouveau"
  libunwind: "enabled"
  rusticl_enabled: "radeonsi"
  optimize-debug: "false"
  meson-lto-flags: ''

  # The key override: all codecs including H.264/H.265
  video_codecs: "all"

  # Matches mesa-extra.bst for debug-symbol organisation (stripdir is debug-only)
  stripdir-suffix: "extensions/mesa/mesa.bst"

  meson-local: >-
    -Db_ndebug=true
    -Degl=enabled
    -Dgallium-drivers=%{gallium_drivers}
    -Dgallium-rusticl=true
    -Dgallium-va=enabled
    -Dgallium-mediafoundation=disabled
    -Dgallium-rusticl-enable-drivers=%{rusticl_enabled}
    -Dgbm=enabled
    -Dgbm-backends-path="/usr/lib/%{gcc_triplet}/GL/lib/gbm"
    -Dgles1=disabled
    -Dgles2=enabled
    -Dglvnd=enabled
    -Dglx=auto
    -Dlibunwind=%{libunwind}
    -Dllvm=enabled
    -Dlmsensors=disabled
    -Dmicrosoft-clc=disabled
    -Dandroid-libbacktrace=disabled
    -Dplatforms=x11,wayland
    -Dvalgrind=disabled
    -Dvulkan-layers=device-select,overlay,intel-nullhw,screenshot,anti-lag
    -Dvulkan-drivers=%{vulkan_drivers}
    -Dvulkan-icd-dir="%{libdir}/vulkan/icd.d"
    -Dxlib-lease=enabled
    -Dzstd=enabled
    -Dvideo-codecs=%{video_codecs}
    -Drust_std=2021
    -Dintel-rt=%{intel-rt}
    -Dteflon=true
    -Ddisplay-info=disabled

config:
  install-commands:
    (>):
    - |
      mkdir -p "%{install-root}%{libdir}"
      mv "%{install-root}%{sysconfdir}/OpenCL" "%{install-root}%{libdir}/"
      ln -s libEGL_mesa.so.0 %{install-root}%{libdir}/libEGL_indirect.so.0
      ln -s libGLX_mesa.so.0 %{install-root}%{libdir}/libGLX_indirect.so.0
      rm -f "%{install-root}%{libdir}"/libGLESv2*
      rm -f "%{install-root}%{libdir}/libGLX_mesa.so"
      rm -f "%{install-root}%{libdir}/libEGL_mesa.so"
      rm -f "%{install-root}%{libdir}/libglapi.so"
    - |
      if [ -f "%{install-root}%{includedir}/vulkan/vulkan_intel.h" ]; then
        mkdir -p "%{install-root}%{includedir}/%{gcc_triplet}/vulkan"
        mv "%{install-root}%{includedir}/vulkan/vulkan_intel.h" "%{install-root}%{includedir}/%{gcc_triplet}/vulkan/"
      fi
    - |
      ln -sr '%{install-root}%{datadir}/glvnd' '%{install-root}%{prefix}/glvnd'
      mkdir -p '%{install-root}%{prefix}/vulkan'
      ln -sr '%{install-root}%{libdir}/vulkan/icd.d' '%{install-root}%{prefix}/vulkan/icd.d'
      ln -sr '%{install-root}%{datadir}/vulkan/explicit_layer.d' '%{install-root}%{prefix}/vulkan/explicit_layer.d'
      ln -sr '%{install-root}%{datadir}/vulkan/implicit_layer.d' '%{install-root}%{prefix}/vulkan/implicit_layer.d'
      ln -sr '%{install-root}%{libdir}/OpenCL' '%{install-root}%{prefix}/OpenCL'
      ln -sr '%{install-root}%{libdir}/vdpau' '%{install-root}%{prefix}/vdpau'
    - |
      DIR="%{install-root}%{project_licensedir}/mesa"
      mkdir -p "$DIR"
      cp -rv licenses/* "$DIR"

public:
  bst:
    split-rules:
      devel:
        (>):
        - '%{libdir}/libgbm.so'
        - '%{libdir}/libglapi.so'
        - '%{libdir}/libwayland-egl.so'
        - '%{libdir}/libMesaOpenCL.so'
        - '%{libdir}/d3d/d3dadapter9.so'
  cpe:
    product: mesa
    vendor: mesa3d
