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
- freedesktop-sdk.bst:public-stacks/runtime-minimal.bst

variables:
  version: "0.2026.08.18.02.52.stable.00"
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
      url: warp_releases:stable/v0.2026.08.18.02.52.stable_00/warp-terminal_0.2026.08.18.02.52.stable.00_amd64.deb
      ref: b702a6d32841d50769887c8438cd9a934222463852cb79516abc094ea53e075f
  - arch == "aarch64":
      url: warp_releases:stable/v0.2026.08.18.02.52.stable_00/warp-terminal_0.2026.08.18.02.52.stable.00_arm64.deb
      ref: a4b312889022ee43bf066289ff53149b3a4808e10003b65f81c7984c719b9d2b
