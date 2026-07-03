# plymouth-theme — pins the boot-splash theme to "glow".
#
# fdsdk's plymouth.bst ships plymouthd.defaults with Theme=bgrt, which
# renders the UEFI firmware logo (ACPI BGRT) behind the spinner. "glow"
# has no firmware-background dependency and instead fades in a large
# centered watermark image — closer to what a custom krytis logo needs.
#
# This file must be depended on by BOTH stacks/desktop.bst (so the theme
# is set on the final rootfs) and core/initramfs.bst (so dracut's plymouth
# module bakes the "glow" theme assets into the initramfs instead of the
# default "bgrt" ones — dracut only packages the currently-configured
# theme, not all of them).
kind: manual

build-depends:
- freedesktop-sdk.bst:public-stacks/runtime-minimal.bst

depends:
- freedesktop-sdk.bst:components/plymouth.bst

# Upstream plymouth ships /etc/plymouth/plymouthd.conf itself (a fully
# commented-out "Administrator customizations go in this file" template).
# We intentionally overwrite it with a live Theme= setting, which BST's
# overlap detection (fatal-warnings: overlaps in project.conf) flags
# unless whitelisted here.
public:
  bst:
    overlap-whitelist:
    - /etc/plymouth/plymouthd.conf

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
    Theme=glow
    EOF
