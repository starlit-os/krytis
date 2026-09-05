kind: manual

# Equibop: custom Discord desktop app, Vesktop/Equicord-derived (https://equicord.org).
# Pre-built portable tarball, x86_64 + aarch64.
#
# Why the portable tar.gz and not the .deb: both assets carry a byte-identical
# payload (same `equibop`, `app.asar`, `arrpc`, `chrome-sandbox`), but the .deb
# also ships `resources/package-type` containing "deb". electron-updater picks
# its Linux updater by reading that file, so it instantiates DebUpdater — which
# *is* active, polls GitHub on every launch (src/main/startup.ts imports
# ./updater, which calls checkForUpdates() at module load), opens an update
# window, downloads ~190 MB, then fails because neither dpkg nor apt exists on
# this image. With no package-type file, electron-updater falls back to
# AppImageUpdater, whose isUpdaterActive() returns false when $APPIMAGE is
# unset, so checkForUpdates() short-circuits to null and the updater is inert.
# See docs/skills/bst.md § Electron self-updaters on a read-only image.
#
# Layout: the `equibop` binary has RPATH $ORIGIN, so the bundle must stay in one
# directory — installed to /usr/lib/equibop/ with /usr/bin/equibop symlinked in,
# the same shape as zed.bst and zen-browser.bst. Deliberately not /opt: bootc
# maps /opt to /var/opt, which is empty runtime state on every boot (warp.bst).
#
# chrome-sandbox ships mode 0755, not setuid, and that is correct here: krytis
# re-enables kernel.unprivileged_userns_clone
# (files/desktop-tweaks/sysctl.d/99-userns.conf), so Chromium uses the namespace
# sandbox and needs no setuid helper. Upstream's postinst only chmods it 4755 on
# systems where user namespaces are unavailable.
#
# The portable tarball ships no .desktop entry and no icon, so both are provided
# here: the entry is hand-authored (upstream's own linux.desktop.entry from
# package.json, with Exec pointed at the /usr/bin symlink), and the icon is
# upstream build/icon.svg — byte-identical to the one electron-builder generates
# into the .deb — pinned at a commit rather than a release tag so version bumps
# do not need to re-pin it. mise run equibop-update warns if upstream changes it.
#
# Update path: mise run equibop-update / track-equibop CI job.
# Closes #609.

depends:
- freedesktop-sdk.bst:public-stacks/runtime-gnu.bst
# DT_NEEDED of the `equibop` binary, grouped by provider. gtk3 covers gtk/cairo/
# pango/atk/gdk-pixbuf/glib and the X11 client libs it links (libX11,
# libXcomposite, libXdamage, libXext, libXfixes, libXrandr, libxcb, expat).
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
# Verified on a booted krytis: `ldconfig -p` reports
# libgbm.so.1 => /usr/lib/x86_64-linux-gnu/GL/default/lib/libgbm.so.1.
# Consequence: `bst shell` on this element alone cannot exec the binary — it
# fails with "libgbm.so.1: cannot open shared object file". Smoke-test by
# checking the artifact out and running it on a booted image instead.
- freedesktop-sdk.bst:extensions/mesa/mesa.bst
# Not in DT_NEEDED — dlopened at runtime, and each is in upstream's own
# Depends: line. libsecret backs Electron's safeStorage keyring, libnotify
# desktop notifications, pipewire screen share and @vencord/venmic audio
# capture, libXtst/libXss the global-keybind and idle-detection paths.
- freedesktop-sdk.bst:components/libsecret.bst
- freedesktop-sdk.bst:components/libnotify.bst
- freedesktop-sdk.bst:components/pipewire.bst
- freedesktop-sdk.bst:components/xorg-lib-xtst.bst
- freedesktop-sdk.bst:components/xorg-lib-xscrnsaver.bst
# shell.openExternal shells out to xdg-open for links and attachments.
- desktop/xdg-utils.bst

variables:
  version: "3.3.0"
  strip-binaries: ''

config:
  strip-commands:
  - ':'

  install-commands:
  - |
    install -d "%{install-root}%{indep-libdir}/equibop"
    cp -a bundle/. "%{install-root}%{indep-libdir}/equibop/"

    install -d "%{install-root}%{bindir}"
    ln -s "%{indep-libdir}/equibop/equibop" "%{install-root}%{bindir}/equibop"

    install -Dm644 equibop.svg \
      "%{install-root}%{datadir}/icons/hicolor/scalable/apps/equibop.svg"

    install -Dm644 /dev/null "%{install-root}%{datadir}/applications/equibop.desktop"
    cat > "%{install-root}%{datadir}/applications/equibop.desktop" <<'EOF'
    [Desktop Entry]
    Name=Equibop
    GenericName=Internet Messenger
    Comment=Equibop is a custom Discord desktop app
    Exec=equibop %U
    Icon=equibop
    Terminal=false
    Type=Application
    StartupNotify=true
    StartupWMClass=equibop
    Categories=Network;InstantMessaging;Chat;
    Keywords=discord;vencord;equicord;electron;chat;equibop;
    MimeType=x-scheme-handler/discord;
    EOF
  - "%{install-extra}"

sources:
# directory: bundle keeps the app tree out of the staging root so the icon
# source below can sit beside it and `cp -a bundle/.` stays version-proof.
# kind: tar strips the single top-level equibop-<ver>/ directory by default.
- kind: tar
  directory: bundle
  (?):
  - arch == "x86_64":
      url: github_files:Equicord/Equibop/releases/download/v3.3.0/equibop-3.3.0.tar.gz
      ref: 7ab42e569da77f73d8c3dbdedc041b161d6339119fdd9843c477b92be6154774
  - arch == "aarch64":
      url: github_files:Equicord/Equibop/releases/download/v3.3.0/equibop-3.3.0-arm64.tar.gz
      ref: 2d51491583c5410258fa35b1a19db9d15c08ae2387033c82c8b7d554f08e3a11
- kind: remote
  filename: equibop.svg
  url: github_raw:Equicord/Equibop/59012b50cdebbeabfb2f0ca1443c7be3dcfb7efa/build/icon.svg
  ref: 4965ba51836bdc1d4d0c9d672b4e98ab59b9189c06ff6d23e5c27e2c59ad2f05
