# zram-generator's default config: one zstd zram0 swap device sized at half of RAM.
#
# Until gnome-build-meta eaa10b21 this file came from gnome-build-meta's own
# gnomeos-deps/zram-generator.bst, whose install-commands wrote it. That commit moved
# the element to freedesktop-sdk-extra (components/zram-generator.bst), which builds
# only the generator and ships no config. zram-generator creates no device unless
# a config file with at least one section exists (upstream README, v1.2.1), and
# zswap without a swap device behind it does nothing, so dropping this file would
# leave the image with no swap at all. The content is byte-identical to what
# gnome-build-meta shipped; whether krytis should keep zram at all is #510's
# evaluation (docs/plans/2026-10-13-zram-vs-zswap-evaluation.md), not this file's.

kind: manual

build-depends:
- freedesktop-sdk.bst:public-stacks/runtime-gnu.bst

variables:
  strip-binaries: ''

config:
  strip-commands:
  - ':'

  install-commands:
  - |
    install -Dm644 /dev/null "%{install-root}%{indep-libdir}/systemd/zram-generator.conf"
    cat > "%{install-root}%{indep-libdir}/systemd/zram-generator.conf" <<'EOF'
    [zram0]
    zram-size = ram / 2
    compression-algorithm = zstd
    EOF
