# plymouth-theme — pins the boot-splash theme to "spinner" and swaps in a
# krytis watermark logo in place of the freedesktop-sdk swirl.
#
# fdsdk's plymouth.bst ships plymouthd.defaults with Theme=bgrt, which
# renders the UEFI firmware logo (ACPI BGRT) behind the spinner. "spinner"
# has no firmware-background dependency — it's the same two-step module
# and animation assets bgrt reuses, minus the firmware layer. "glow" (an
# earlier candidate, see docs/skills/desktop.md) was dropped for being too
# visually heavy (pie-chart fill + merge-fade logo reveal).
#
# spinner already has a watermark slot: fdsdk's plymouth-logo.bst (a
# transitive dep of plymouth.bst) installs freedesktop-sdk-40.png to
# %{datadir}/plymouth/themes/spinner/watermark.png. We overwrite that same
# path with our own logo rather than inventing a separate theme directory.
#
# This file must be depended on by BOTH stacks/desktop.bst (so the theme
# is set on the final rootfs) and core/initramfs.bst (so dracut's plymouth
# module bakes the "spinner" theme assets into the initramfs instead of the
# default "bgrt" ones — dracut only packages the currently-configured
# theme, not all of them).
kind: manual

sources:
- kind: local
  path: files/plymouth/krytis-watermark.png

build-depends:
- freedesktop-sdk.bst:public-stacks/runtime-minimal.bst

depends:
- freedesktop-sdk.bst:components/plymouth.bst

# Upstream plymouth ships /etc/plymouth/plymouthd.conf itself (a fully
# commented-out "Administrator customizations go in this file" template).
# plymouth-logo.bst (transitive dep of plymouth.bst) ships spinner's
# watermark.png. We intentionally overwrite both, which BST's overlap
# detection (fatal-warnings: overlaps in project.conf) flags unless
# whitelisted here.
public:
  bst:
    overlap-whitelist:
    - /etc/plymouth/plymouthd.conf
    - /usr/share/plymouth/themes/spinner/watermark.png

variables:
  strip-binaries: ''

config:
  strip-commands:
  - ':'

  install-commands:
  - |
    install -Dm644 /dev/stdin \
      "%{install-root}%{sysconfdir}/plymouth/plymouthd.conf" <<'EOF'
    [Daemon]
    Theme=spinner
    EOF
  - install -Dm644 krytis-watermark.png "%{install-root}%{datadir}/plymouth/themes/spinner/watermark.png"
