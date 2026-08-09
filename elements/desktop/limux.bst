kind: manual

# Limux: GPU-accelerated terminal workspace manager
# (https://github.com/am-will/limux). Embedded Ghostty renderer, split panes,
# tabbed terminals, persistent folder-named workspaces, WebKitGTK browser
# panes, and a CLI (limux notify / new-pane / send / agent-team) a coding
# agent can drive from inside its own pane. Closes #550.
#
# Prebuilt upstream tarball — x86_64 only (no aarch64 asset; project.conf's
# arch option is x86_64-only anyway). glibc floor is GLIBC_2.39 on the two
# binaries and GLIBC_2.38 on libghostty.so; fdsdk 25.08 ships 2.42.
#
# Installed with the upstream /usr prefix layout on purpose: limux-cli's
# resolve_host_binary() derives <prefix>/libexec/limux/limux-host from
# current_exe(), so /usr/bin/limux finds /usr/libexec/limux/limux-host with no
# patching. Do NOT relocate under %{indep-libdir}/limux/bin the way zed.bst
# does — that would break host discovery.
#
# The bundled libghostty.so lands in %{indep-libdir}/limux/ and is made
# findable by config/limux-ldconfig.bst: both binaries carry
# RUNPATH=/usr/local/lib/limux, and /usr/local is a symlink to /var/usrlocal
# (bootc tmpfiles), i.e. empty runtime state on every boot.
#
# webkitgtk-6.0 is a hard NEEDED of limux-host (libwebkitgtk-6.0.so.4,
# libjavascriptcoregtk-6.0.so.1) — the browser pane is not optional. It is the
# only reason webkit enters the krytis image at all.
#
# Upstream ships no LICENSE file in the repo or the tarball (Cargo.toml
# declares MIT), so fdsdk's %{install-extra} licence harvest finds nothing for
# this element. Ghostty's own MIT text is already in the image via
# desktop/ghostty.bst.
#
# Update path: mise run limux-update / track-limux CI job.

build-depends:
- freedesktop-sdk.bst:public-stacks/runtime-minimal.bst

depends:
- freedesktop-sdk.bst:public-stacks/runtime-minimal.bst
- freedesktop-sdk.bst:components/fontconfig.bst
- gnome-build-meta.bst:sdk/gtk.bst
- gnome-build-meta.bst:sdk/libadwaita.bst
- gnome-build-meta.bst:sdk/webkitgtk-6.0.bst

variables:
  version: "0.1.23"
  strip-binaries: ''

config:
  strip-commands:
  - ':'

  install-commands:
  # install.sh is deliberately not shipped — its /etc/ld.so.conf.d write is
  # config/limux-ldconfig.bst's job, and its ldconfig/gtk-update-icon-cache
  # calls are handled by image.bst's assembly step.
  - install -Dm755 limux "%{install-root}%{bindir}/limux"
  - install -Dm755 libexec/limux/limux-host "%{install-root}%{libexecdir}/limux/limux-host"
  - install -Dm755 lib/libghostty.so "%{install-root}%{indep-libdir}/limux/libghostty.so"

  # Ghostty themes + shell-integration + terminfo. limux-host probes
  # <prefix>/share/limux/ghostty first, then /usr/share/ghostty; ship the
  # fork's own copy rather than relying on desktop/ghostty.bst's 1.3.1 tree.
  - install -d "%{install-root}%{datadir}"
  - cp -a share/limux "%{install-root}%{datadir}/"

  # Exec=/TryExec=limux are already the bare command name upstream (resolved
  # via PATH); install.sh rewrites them to an absolute path with sed, which
  # runtime-minimal does not provide, and a bare name is valid per the
  # desktop-entry spec.
  - install -Dm644 share/applications/dev.limux.linux.desktop "%{install-root}%{datadir}/applications/dev.limux.linux.desktop"
  - install -Dm644 share/metainfo/dev.limux.linux.metainfo.xml "%{install-root}%{datadir}/metainfo/dev.limux.linux.metainfo.xml"
  - install -d "%{install-root}%{datadir}/icons"
  - cp -a share/icons/hicolor "%{install-root}%{datadir}/icons/"
  - "%{install-extra}"

sources:
- kind: tar
  url: github_files:am-will/limux/releases/download/v0.1.23/limux-0.1.23-linux-x86_64.tar.gz
  ref: 6d8eadcbd3817c26403899bdf1ecde69e4e1d8a206119596eead6f3322134a7a
