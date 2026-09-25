kind: manual

variables:
  # Zig emits its own build-id/debug layout; the fdsdk stripper mangles it.
  # Same treatment as ghostty.bst.
  strip-binaries: ""

# Séance — GTK4/libadwaita scrolling terminal multiplexer that tracks AI coding
# agent sessions (Claude Code, Codex, OpenCode, Pi, Antigravity). Terminal
# emulation comes from libghostty: seance vendors ghostty as a git submodule and
# builds it with `app-runtime = none`, driving GTK itself.
#
# Built from source rather than shipping upstream's AppImage on purpose. That
# AppImage is produced by linuxdeploy-plugin-gtk, whose AppRun hook contains an
# unconditional `export GDK_BACKEND=x11` — it overrides any GDK_BACKEND the
# caller sets, so the AppImage always lands on XWayland. seance itself links
# both backends (build.zig links x11 *and* wayland-client); a source build runs
# natively on Wayland. See krytis#956.
#
# `share/seance/{ghostty,terminfo}`, not `share/ghostty` + `share/terminfo`:
# upstream's default install path collides with desktop/ghostty.bst and with
# ncurses' terminfo database, and project.conf makes overlaps fatal. The
# relocation is upstream-sanctioned, not a hack — src/ghostty_bridge.zig probes
# `share/seance/ghostty` *before* `share/ghostty` precisely so distro packages
# can move it, and derives TERMINFO as its sibling. Same layout as the AUR
# package. This is why the element needs no overlap-whitelist entry.

build-depends:
  - desktop/zig-0.16.bst
  - freedesktop-sdk.bst:components/tar.bst
  - freedesktop-sdk.bst:components/gzip.bst
  - freedesktop-sdk.bst:components/gettext.bst
  - freedesktop-sdk.bst:components/pkg-config.bst
  # build.zig's requirePkgConfig() hard-fails unless `gl` and `egl` resolve via
  # pkg-config. components/libglvnd.bst deliberately deletes gl.pc/egl.pc from
  # its own install; components/mesa-headers.bst is what puts them back (along
  # with the GL/EGL headers), and it is `devel: /**` so it stays build-only.
  - freedesktop-sdk.bst:components/mesa-headers.bst

depends:
  - gnome-build-meta.bst:sdk/gtk.bst
  - gnome-build-meta.bst:sdk/libadwaita.bst
  # Linked directly by seance (pkg-config `.force`), not reached through gtk.
  - freedesktop-sdk.bst:components/libnotify.bst
  - gnome-build-meta.bst:core-deps/libcanberra.bst
  - freedesktop-sdk.bst:components/xorg-lib-x11.bst
  - freedesktop-sdk.bst:components/wayland.bst
  - freedesktop-sdk.bst:components/fontconfig.bst
  # libghostty is linked as a static archive with system integration, so the
  # libraries it uses internally are not embedded — seance links freetype2,
  # harfbuzz and oniguruma itself (build.zig, "System libraries used
  # internally by libghostty"). oniguruma has no element of its own: fdsdk
  # builds it as jq's vendored submodule, and components/jq.bst is what ships
  # libonig.so* plus oniguruma.pc. jq is already in the image, so this adds
  # nothing new.
  - freedesktop-sdk.bst:components/freetype.bst
  - freedesktop-sdk.bst:components/harfbuzz.bst
  - freedesktop-sdk.bst:components/jq.bst
  # libGL/libEGL dispatch. mesa-headers only build-depends here, so its own
  # runtime-depends on libglvnd never reaches the image — name it explicitly.
  - freedesktop-sdk.bst:components/libglvnd.bst
  - freedesktop-sdk.bst:public-stacks/runtime-gnu.bst

sources:
  # seance source tarball (vendors the ghostty submodule)
  - kind: tar
    url: github_files:no1msd/seance/releases/download/v0.1.7/seance-0.1.7-src.tar.gz
    ref: 3e3cb0dbb6a18bdc90f8dd1f7bad2ad15244e8ba55a9427447f145e15142119e
    base-dir: 'seance-*'

  # Zig package dependencies — generated, do not hand-edit.
  # Regenerate with the element's `-update` mise task.
  - kind: remote
    url: ghostty_deps:translate_c-80f8b6e4f45a303268717d8e5f4f91d7837138bb.tar.gz
    ref: 38c9e59d58f36e3481f6fa38f11fe59c63c12492fccf399ca56f3dfcce17b53e
    directory: zig-deps

  - kind: remote
    url: ghostty_deps:ghostty-themes-release-20260824-153547-75c93ee.tgz
    ref: b1fd1f31057f97c1274db03c6ce44960837a1a41f52275cbc64aee2e6e34eb9e
    directory: zig-deps

  - kind: remote
    url: ghostty_deps:libxev-9ce8e8e6ff89e583258a7f8e7adeeeaeae8611bf.tar.gz
    ref: e2b9b224cd78101156abb8f46479a51f6cce66c4815c632856e20a1440dd02b7
    directory: zig-deps

  - kind: remote
    url: ghostty_deps:vaxis-1dbbe575dff4586fe51e3217aa5c3fecdcbb6089.tar.gz
    ref: 3ea050e905887c46bca1a2c18e41d6edf574c1aa6ebfbc5cf3c52846275e4fa8
    directory: zig-deps

  - kind: remote
    url: ghostty_deps:z2d-7dbae85c81784dba9988320bf9543ed9a81350c8.tar.gz
    ref: e55c9d0b156edaddfea32fb1c0e3597e1b6306b9a4ec1888e2f8008c598bced8
    directory: zig-deps

  - kind: remote
    url: ghostty_deps:zig_objc-c8de82ff80281215ad92900866dab7103a8efa8b.tar.gz
    ref: 831eaec554bb23ef20229f1e705d8f53e8a29c829840bb8d0f5edb05c76d6df0
    directory: zig-deps

  - kind: remote
    url: ghostty_deps:zig_js-3c23860e47fdcdc5af805efb7fd0bdac5fd3e9bc.tar.gz
    ref: a2ff488a244301f4e59469a5232aad6869b01acc50f7d7ed2647c029a57d4b3b
    directory: zig-deps

  - kind: remote
    url: ghostty_deps:uucode-2826a37a4562284fdacd8fa029d49509cc9bffcd.tar.gz
    ref: 7e76fc7fab1e7ac728c52b35bbb3e5b8c639841abfc7fe1a4bcb13050594bc9e
    directory: zig-deps

  - kind: remote
    url: ghostty_deps:wayland-0.6.0-lQa1kqz8AQADQmdNJsNhLoNHcnEGEUjrOaPV-dtEnEmX.tar.gz
    ref: 759a632e36a948e0e412d2d74a43a69d2f34e65d40289a16af7aa3725852ef25
    directory: zig-deps

  - kind: remote
    url: ghostty_deps:zf-c35c421f84895193246db06c40683c1a30e616ef.tar.gz
    ref: ca4bc109fd9d97cedae2f5bdb879cc78c346d43c14a34e3a2abd2ee9208c8547
    directory: zig-deps

  - kind: remote
    url: ghostty_deps:gobject-2026-07-28-36-1.tar.zst
    ref: 9014db570db06e3fbfcfadb7b32aa8addacc6969e701650683c1c74428adba6c
    directory: zig-deps

  - kind: remote
    url: ghostty_deps:wayland-9cb3d7aa9dc995ffafdbdef7ab86a949d0fb0e7d.tar.gz
    ref: ea4191d68e437677e51f3aacde27829810144e931d397a327dc6035e2c39c50d
    directory: zig-deps

  - kind: remote
    url: ghostty_deps:N-V-__8AAFdWDwA0ktbNUi9pFBHCRN4weXIgIfCrVjfGxqgA.tar.gz
    ref: dd2df14ab5f41038257aaedcc4b5fb9ac0ee018f3f0f94af9097028e60d33223
    directory: zig-deps

  - kind: remote
    url: ghostty_deps:plasma_wayland_protocols-12207e0851c12acdeee0991e893e0132fc87bb763969a585dc16ecca33e88334c566.tar.gz
    ref: 5c58ba214acd8e6bca3426dc08b022c46a8dd997b29a1b3e28badf71c20df441
    directory: zig-deps

  - kind: remote
    url: ghostty_deps:JetBrainsMono-2.304.tar.gz
    ref: c57a691e8b82ad098b5963f3959032e4038f391087af7715885ba59046105cc4
    directory: zig-deps

  - kind: remote
    url: ghostty_deps:NerdFontsSymbolsOnly-3.4.0.tar.gz
    ref: 1164d1b956d4bde248d7b2f0998c43cc94f5202431a1564a793895b1e73b0d04
    directory: zig-deps

  - kind: remote
    url: ghostty_deps:sentry-1220446be831adcca918167647c06c7b825849fa3fba5f22da394667974537a9c77e.tar.gz
    ref: 2ac6497cc8d61a8d31093e47addb8c9b2c45b16b0705bb334a835b6423c318df
    directory: zig-deps

  - kind: remote
    url: ghostty_deps:libpng-1220aa013f0c83da3fb64ea6d327f9173fa008d10e28bc9349eac3463457723b1c66.tar.gz
    ref: fecc95b46cf05e8e3fc8a414750e0ba5aad00d89e9fdf175e94ff041caf1a03a
    directory: zig-deps

  - kind: remote
    url: ghostty_deps:DearBindings_v0.17_ImGui_v1.92.5-docking.tar.gz
    ref: 8bfec500e00926f679853ee23d67cc392d3c3181733ca4704738651d3f70baa3
    directory: zig-deps

  - kind: remote
    url: ghostty_deps:N-V-__8AAEbOfQBnvcFcCX2W5z7tDaN8vaNZGamEQtNOe0UI.tar.gz
    ref: c816c20e8c75f3e15ae867350e79925502d1a6a85938bb1a73b8927e5f31f9cb
    directory: zig-deps

  - kind: remote
    url: ghostty_deps:gettext-0.24.tar.gz
    ref: c918503d593d70daf4844d175a13d816afacb667c06fba1ec9dcd5002c1518b7
    directory: zig-deps

  - kind: remote
    url: ghostty_deps:harfbuzz-11.0.0.tar.xz
    ref: f16351bafe214725fe2c1d5b59f0d93e49905a4b247899fb90d70cff953a2b9b
    directory: zig-deps

  - kind: remote
    url: ghostty_deps:oniguruma-1220c15e72eadd0d9085a8af134904d9a0f5dfcbed5f606ad60edc60ebeccd9706bb.tar.gz
    ref: 001aa1202e78448f4c0bf1a48c76e556876b36f16d92ce3207eccfd61d99f2a0
    directory: zig-deps

  - kind: remote
    url: ghostty_deps:freetype-1220b81f6ecfb3fd222f76cf9106fecfa6554ab07ec7fdc4124b9bb063ae2adf969d.tar.gz
    ref: 427201f5d5151670d05c1f5b45bef5dda1f2e7dd971ef54f0feaaa7ffd2ab90c
    directory: zig-deps

  - kind: remote
    url: ghostty_deps:gtk4-layer-shell-1.1.0.tar.gz
    ref: 98284281260a5eef5b4f63a55f16c4bf6a788a1020a6db037ecb0f71fa336988
    directory: zig-deps

  - kind: remote
    url: ghostty_deps:wayland-protocols-258d8f88f2c8c25a830c6316f87d23ce1a0f12d9.tar.gz
    ref: 5cedcadde81b75e60f23e5e83b5dd2b8eb4efb9f8f79bd7a347d148aeb0530f8
    directory: zig-deps

  - kind: remote
    url: ghostty_deps:spirv_cross-1220fb3b5586e8be67bc3feb34cbe749cf42a60d628d2953632c2f8141302748c8da.tar.gz
    ref: b52b6fcfc45e7fa69b1f06a1362c155473444e2cc09995556b156c53ba6657e3
    directory: zig-deps

  - kind: remote
    url: ghostty_deps:breakpad-b99f444ba5f6b98cac261cbb391d8766b34a5918.tar.gz
    ref: 6cca98943d1a990766cef61077c09aff5938063fe17a1efe1228e5412b6d6ad9
    directory: zig-deps

  - kind: remote
    url: ghostty_deps:fontconfig-2.14.2.tar.gz
    ref: 3ba2dd92158718acec5caaf1a716043b5aa055c27b081d914af3ccb40dce8a55
    directory: zig-deps

  - kind: remote
    url: ghostty_deps:zlib-1220fed0c74e1019b3ee29edae2051788b080cd96e90d56836eea857b0b966742efb.tar.gz
    ref: 17e88863f3600672ab49182f217281b6fc4d3c762bde361935e436a95214d05c
    directory: zig-deps

  - kind: remote
    url: ghostty_deps:highway-66486a10623fa0d72fe91260f96c892e41aceb06.tar.gz
    ref: 87d4f8893ef4e08f224973608ffebf94268a81380ba79c12e8841968c80aa212
    directory: zig-deps

  - kind: remote
    url: ghostty_deps:libxml2-2.11.5.tar.gz
    ref: 6c28059e2e3eeb42b5b4b16489e3916a6346c1095a74fee3bc65cdc5d89a6215
    directory: zig-deps

  - kind: remote
    url: ghostty_deps:wuffs-7411f488fe2e2c205c3d3b3d28638b7356522930.tar.gz
    ref: 17877d346f7988651d6c62e45b2e3b05c86809a6442c5e34612374b2a9719a1c
    directory: zig-deps

  - kind: remote
    url: ghostty_deps:pixels-12207ff340169c7d40c570b4b6a97db614fe47e0d83b5801a932dcd44917424c8806.tar.gz
    ref: 55e83b16d091082502bf149bf457f31f42092c5982650e3ffbae7b48871bf11a
    directory: zig-deps

  - kind: remote
    url: ghostty_deps:glslang-12201278a1a05c0ce0b6eb6026c65cd3e9247aa041b1c260324bf29cee559dd23ba1.tar.gz
    ref: 14a2edbb509cb3e51a9a53e3f5e435dbf5971604b4b833e63e6076e8c0a997b5
    directory: zig-deps

  - kind: remote
    url: github_files:vancluever/arocc/archive/ecbc5c799574e0da2758a961b12efa586007f03c.tar.gz
    ref: aa54487bd727e8fa36744ff0a824dedb2f4ca45f4c2d4d9d2437cf5fd3d0ad1a
    directory: zig-deps

  - kind: remote
    url: github_files:zigimg/zigimg/archive/d695acd97c02e57bb151e8f659d1280f5cd6ca70.tar.gz
    ref: 487794b6f28a8380d17a4960d3c53ef2f466d3075b92e8ebf3f84ec6b568545d
    directory: zig-deps-git

  - kind: remote
    url: github_files:jacobsandlund/uucode/archive/2826a37a4562284fdacd8fa029d49509cc9bffcd.tar.gz
    ref: 7e76fc7fab1e7ac728c52b35bbb3e5b8c639841abfc7fe1a4bcb13050594bc9e
    directory: zig-deps-git

  - kind: remote
    url: github_files:hendriknielaender/zBench/archive/refs/tags/v0.13.0.tar.gz
    ref: 38250dac586b59bd76acc45a08f544ee83bb6153844343aeb69206501d003ee4
    directory: zig-deps

  - kind: remote
    url: github_files:rockorager/libvaxis/archive/c1e1f23be38951c425cdf31af455ba23ef178940.tar.gz
    ref: cfa98fec10847961a1a1faadb046792d7ad10f73a1410b1c1a9fabd3c3050205
    directory: zig-deps-git

config:
  build-commands:
    # Stage 1: set up the Zig cache the offline sandbox will build against.
    - |
      export ZIG_GLOBAL_CACHE_DIR="/tmp/zig-cache"
      export ZIG_LIB_DIR="%{libdir}/zig"
      mkdir -p "$ZIG_GLOBAL_CACHE_DIR/p"

    # Stage 2: populate it from the staged dep tarballs. `zig fetch` computes
    # the content hash `zig build` expects, for git-declared deps as well as
    # plain tarballs — do NOT hand-place git deps under p/<hash>, Zig 0.16
    # ignores such entries and re-fetches over the network, which cannot work
    # in an offline sandbox (see desktop/falcond.bst).
    #
    # No `|| true`: a dep that fails to fetch here fails the build hundreds of
    # steps later with an unrelated-looking error, so stop at the real cause.
    - |
      export ZIG_GLOBAL_CACHE_DIR="/tmp/zig-cache"
      export ZIG_LIB_DIR="%{libdir}/zig"
      for dep in zig-deps/* zig-deps-git/*; do
        echo "Fetching: $dep"
        zig fetch --global-cache-dir "$ZIG_GLOBAL_CACHE_DIR" "$dep"
      done

  install-commands:
    # No `-Dtarget=…-gnu.2.43`, tempting as it looks. Zig 0.16.0's abilists
    # stop at glibc 2.43 while fdsdk 26.08 ships 2.44, so the build logs
    # `zig cannot build new glibc version 2.44.0; providing instead 2.43.0`.
    # That is a warning and harmless — 2.43 stubs cover everything here, since
    # every library seance links tops out at GLIBC_2.43 (`nm -D
    # --with-symbol-versions`). Naming an explicit glibc version to silence it
    # makes the target non-native, at which point Zig uses its own bundled
    # libc headers and stops searching /usr/include entirely: translate-c then
    # dies on `'X11/Xlib.h' not found` from gdkx.h, because x11.pc carries no
    # -I of its own.
    - |
      export ZIG_GLOBAL_CACHE_DIR="/tmp/zig-cache"
      export ZIG_LIB_DIR="%{libdir}/zig"
      DESTDIR="%{install-root}" \
      zig build \
        --prefix /usr \
        --global-cache-dir "$ZIG_GLOBAL_CACHE_DIR" \
        -Doptimize=ReleaseSafe \
        -Dcpu=baseline

    # Move ghostty's resources and the compiled terminfo database out of the
    # paths desktop/ghostty.bst and ncurses already own. See the header comment.
    - |
      mkdir -p "%{install-root}%{datadir}/seance"
      mv "%{install-root}%{datadir}/ghostty" "%{install-root}%{datadir}/seance/ghostty"
      mv "%{install-root}%{datadir}/terminfo" "%{install-root}%{datadir}/seance/terminfo"
