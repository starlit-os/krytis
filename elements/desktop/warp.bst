kind: manual

# Warp: agentic terminal (https://warp.dev). Closes #315.
#
# Official prebuilt .deb from Warp's own apt repository — no build from
# source required. See docs/skills/bst.md § .deb extraction in BST sandbox
# and § Warp: official apt repo, not just GitHub Releases.
build-depends:
- freedesktop-sdk.bst:components/binutils.bst  # ar
- freedesktop-sdk.bst:components/tar.bst       # tar with xz

depends:
- freedesktop-sdk.bst:public-stacks/runtime-gnu.bst

variables:
  version: "0.2026.09.16.08.27.stable.02"
  strip-binaries: ''

config:
  strip-commands:
  - ':'

  build-commands:
  - ar x warp.deb data.tar.xz
  - tar -xJf data.tar.xz

  install-commands:
  # postinst creates /usr/bin/warp-terminal at install time on Debian; BST
  # doesn't run maintainer scripts, so the symlink is recreated here.
  #
  # The .deb payload ships under opt/warpdotdev/warp-terminal/, but bootc's
  # rootfs treats /opt as a symlink to /var/opt (see
  # /usr/lib/tmpfiles.d/10-bootc.conf), and /var isn't part of the immutable
  # composefs image — it's fresh, empty runtime state on every boot. Content
  # staged under /opt never survives into the booted image. Relocate to
  # /usr/lib/warp-terminal/ instead (same pattern as zed.bst): the `warp`
  # binary has no RPATH/RUNPATH and no hardcoded /opt/warpdotdev string refs,
  # so it resolves resources/ relative to itself regardless of install path.
  - install -d "%{install-root}%{indep-libdir}/warp-terminal"
  - cp -a opt/warpdotdev/warp-terminal/. "%{install-root}%{indep-libdir}/warp-terminal/"
  - cp -a usr "%{install-root}/"
  - install -d "%{install-root}%{bindir}"
  - ln -s "%{indep-libdir}/warp-terminal/warp" "%{install-root}%{bindir}/warp-terminal"
  - "%{install-extra}"

sources:
- kind: remote
  filename: warp.deb
  (?):
  - arch == "x86_64":
      url: warp_releases:stable/v0.2026.09.16.08.27.stable_02/warp-terminal_0.2026.09.16.08.27.stable.02_amd64.deb
      ref: 935d7d0b746ca3c7aa111ee902e797f04eea1aa9248b53be495354452553c372
  - arch == "aarch64":
      url: warp_releases:stable/v0.2026.09.16.08.27.stable_02/warp-terminal_0.2026.09.16.08.27.stable.02_arm64.deb
      ref: 2406b97f79688f7277f4e14834b9a43e8c69b51893006ba6acd2cc0d31f33773
