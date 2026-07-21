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
  version: "0.2026.07.15.08.55.stable.01"
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
  - cp -a opt "%{install-root}/"
  - cp -a usr "%{install-root}/"
  - install -d "%{install-root}%{bindir}"
  - ln -s /opt/warpdotdev/warp-terminal/warp "%{install-root}%{bindir}/warp-terminal"
  - "%{install-extra}"

sources:
- kind: remote
  filename: warp.deb
  (?):
  - arch == "x86_64":
      url: warp_releases:stable/v0.2026.07.15.08.55.stable_01/warp-terminal_0.2026.07.15.08.55.stable.01_amd64.deb
      ref: 833192da9626fd8953d3c3bd9460a10158b8b54a10475ed70d1ca7371dfd5033
  - arch == "aarch64":
      url: warp_releases:stable/v0.2026.07.15.08.55.stable_01/warp-terminal_0.2026.07.15.08.55.stable.01_arm64.deb
      ref: d28b890db23b5f7326540d58e62ba2f26c45b278734942613a02961ba1422efc
