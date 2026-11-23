# Swap: zswap in front of a disk swapfile at /var/swap/swapfile, half of RAM (#510).
#
# This replaced zram-generator (zram0, ram / 2, zstd), which the image ran with the
# kernel's default-on zswap stacked in front of it, so every page was compressed
# twice and nothing sat behind zram. On 2026-11-21 that filled on melog and the
# kernel OOM killer fired three times. The data and the decision are in #510 and
# docs/skills/swap-tuning.md.
#
#   bootc/kargs.d/50-zswap.toml   zswap on, zstd, 20 % pool, shrinker on: set
#                                 explicitly, not left to the kernel default
#   sysctl.d/60-krytis-swap.conf  vm.swappiness=100, vm.page-cluster=0, pinned
#   krytis-swapfile-init(.service) creates the swapfile on first boot, in its own
#                                 btrfs subvolume (NOCOW), or skips if /var is
#                                 too small or can't hold one
#   var-swap-swapfile.swap        activates it, wired through a static
#                                 swap.target.wants symlink so existing installs
#                                 pick it up on upgrade
#
# /var/swap is created at runtime: bootc lints against /var content in the image.
# mise run swap-audit (the last gate of mise run build) checks all of the above
# in the built image, and fails if zram-generator comes back.

kind: manual

sources:
- kind: local
  path: files/swap

build-depends:
- freedesktop-sdk.bst:public-stacks/runtime-gnu.bst

variables:
  strip-binaries: ''

config:
  strip-commands:
  - ':'

  install-commands:
  - install -Dm644 -t "%{install-root}%{indep-libdir}/bootc/kargs.d" 50-zswap.toml
  - install -Dm644 -t "%{install-root}%{indep-libdir}/sysctl.d" 60-krytis-swap.conf
  - install -Dm755 -t "%{install-root}/usr/libexec" krytis-swapfile-init
  - |
    install -Dm644 -t "%{install-root}%{indep-libdir}/systemd/system" \
      krytis-swapfile-init.service var-swap-swapfile.swap
    install -d "%{install-root}%{indep-libdir}/systemd/system/swap.target.wants"
    ln -s ../var-swap-swapfile.swap \
      "%{install-root}%{indep-libdir}/systemd/system/swap.target.wants/var-swap-swapfile.swap"
