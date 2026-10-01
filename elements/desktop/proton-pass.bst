kind: manual

# Proton Pass desktop application (https://proton.me/pass).
# x86_64-only pre-built Electron app; no arm64 release from Proton.
# Bundled Electron — no system electron dependency.
# Update path: mise run proton-pass-update / track-proton-pass CI job.
# Closes #206.

build-depends:
- freedesktop-sdk.bst:components/binutils.bst
- freedesktop-sdk.bst:components/tar.bst

depends:
- freedesktop-sdk.bst:public-stacks/runtime-gnu.bst
# DT_NEEDED of `/usr/lib/proton-pass/Proton Pass`, grouped by provider. The
# bundled libffmpeg.so resolves through RPATH $ORIGIN and needs no element.
# gtk3 covers gtk/cairo/pango/atk/glib and the X11 client libs it links
# (libX11, libXcomposite, libXdamage, libXext, libXfixes, libXrandr, libxcb,
# expat). The bundled native module
# (resources/app.asar.unpacked/.webpack/main/native_modules/*.node) links
# libxkbcommon too.
- freedesktop-sdk.bst:components/gtk3.bst
- freedesktop-sdk.bst:components/nss.bst
- freedesktop-sdk.bst:components/at-spi2-core.bst
- freedesktop-sdk.bst:components/libxkbcommon.bst
- freedesktop-sdk.bst:components/alsa-lib.bst
- freedesktop-sdk.bst:components/cups.bst
- freedesktop-sdk.bst:components/dbus.bst
- freedesktop-sdk.bst:components/systemd.bst
# libgbm.so.1, also DT_NEEDED. fdsdk installs mesa under a non-standard prefix
# (%{libdir}/GL/default/lib), so this dep alone does not make it loadable — what
# resolves it is the /etc/ld.so.conf.d/00_mesa.conf that
# freedesktop-sdk.bst:vm/mesa-default.bst installs from stacks/desktop.bst.
# Same mechanism as desktop/equibop.bst, and the same consequence: `bst shell`
# on this element alone cannot exec the binary.
- freedesktop-sdk.bst:extensions/mesa/mesa.bst
# Not in DT_NEEDED — dlopened at runtime (found with `strings` on the binary).
# libsecret-1 backs Chromium's os_crypt key storage, libnotify Electron
# notifications; both degrade silently when missing. libnotify is also in
# upstream's .deb Depends: line.
# Deliberately absent: libXtst (in the .deb Depends:, but nothing in the bundle
# references it) and pipewire (Chromium's WebRTC screen capture; Proton Pass
# never captures the screen).
- freedesktop-sdk.bst:components/libsecret.bst
- freedesktop-sdk.bst:components/libnotify.bst
# shell.openExternal shells out to xdg-open for links; xdg-utils is in the .deb
# Depends: line too.
- desktop/xdg-utils.bst

variables:
  version: "1.41.1"
  strip-binaries: ''

config:
  strip-commands:
  - ':'

  build-commands:
  - ar x proton-pass.deb data.tar.xz
  - tar -xJf data.tar.xz

  install-commands:
  - cp -a usr "%{install-root}/"
  - "%{install-extra}"

sources:
- kind: remote
  filename: proton-pass.deb
  url: proton_me:download/pass/linux/proton-pass_1.41.1_amd64.deb
  ref: bd02d9b56022b448000c2b0be3771a7d6624672faebc33b7146cb17775e65e88
