kind: autotools

# freedesktop-sdk's components/btrfs-progs.bst, mirrored here so one patch can
# be applied on top of it. It overrides components/btrfs-progs.bst in the
# freedesktop-sdk junction (see elements/freedesktop-sdk.bst overrides).
#
# The patch makes mkfs.btrfs flush its "wipe the old signatures" zeroes before
# it discards the device (#1294). Since v6.16.1 the discard comes second, and
# BLKDISCARD drops the unwritten zeroes from the page cache. On a device that
# ignores the discard, the previous filesystem's signatures survive. A reinstall
# over an encrypted disk then keeps both LUKS2 headers, and fisherman's plain
# remount fails with "unknown filesystem type 'crypto_LUKS'". Upstream tracking:
# #1302.
#
# Everything except the patch source and the `freedesktop-sdk.bst:` prefixes
# mirrors freedesktop-sdk exactly.
#
# Update path: tied to the freedesktop-sdk.bst junction ref, with no separate
# tracking. It is deliberately not in the track-bst-sources.yml matrix:
# `bst source track` would fetch btrfs-progs' latest tag and drift from the
# junction. `mise run btrfs-progs-check` checks this copy for drift against the
# junction and checks that the patch still applies.
#
# Delete this element, the patch, the check task and the overrides entry once
# the junction's btrfs-progs persists the zeroing before it discards (#1302).

build-depends:
- freedesktop-sdk.bst:public-stacks/buildsystem-autotools.bst
- freedesktop-sdk.bst:components/asciidoc.bst
- freedesktop-sdk.bst:components/docbook-xsl.bst
- freedesktop-sdk.bst:components/libxslt.bst
- freedesktop-sdk.bst:components/python3-setuptools.bst
- freedesktop-sdk.bst:components/python3-sphinx-rtd-theme.bst
- freedesktop-sdk.bst:components/python3-sphinx.bst
- freedesktop-sdk.bst:components/xmlto.bst

depends:
- freedesktop-sdk.bst:public-stacks/runtime-minimal.bst
- freedesktop-sdk.bst:components/e2fsprogs.bst
- freedesktop-sdk.bst:components/lzo.bst
- freedesktop-sdk.bst:components/systemd-libs.bst
- freedesktop-sdk.bst:components/zstd.bst

variables:
  # Makefile not generated inside build-dir
  build-dir: ''

sources:
- kind: git_repo
  url: kernel:linux/kernel/git/kdave/btrfs-progs.git
  track: v*
  ref: v7.1-0-g4ab0e80be9e3bb1db2e6038e6d4316d35fb7ba8b
- kind: patch
  path: patches/btrfs-progs/flush-zeroing-before-discard.patch
