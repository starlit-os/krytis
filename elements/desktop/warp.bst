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
  version: "0.2026.09.02.08.27.stable.01"
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
      url: warp_releases:stable/v0.2026.09.02.08.27.stable_01/warp-terminal_0.2026.09.02.08.27.stable.01_amd64.deb
      ref: abb17d2f31fc13cd6b215884bec709fe55c53232d3e1acc9efb56048a14d34e1
  - arch == "aarch64":
      url: warp_releases:stable/v0.2026.09.02.08.27.stable_01/warp-terminal_0.2026.09.02.08.27.stable.01_arm64.deb
      ref: e66ab91b82d62c2906a10d53717d9e0093a45c57818e9f2d3cc2b9046d60f8f0
