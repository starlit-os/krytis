# fido2-root-unlock.bst: make the ROOT volume attempt FIDO2 unlock.
#
# The baked karg rd.luks.options=fido2-device=auto does not reach the root volume:
# systemd-gpt-auto-generator creates that unit and builds its own option string,
# ignoring the karg entirely. Verified on hardware — the boot log showed only
# "No valid TPM2 token data found" and no FIDO2 attempt at all, with the karg present
# on /proc/cmdline throughout.
#
# This ships a drop-in on the generator-created systemd-cryptsetup@root.service that
# restates ExecStart with fido2-device=auto added. The file itself carries the full
# reasoning and the upstream coupling it creates.
#
# The drop-in must reach the INITRD, not just the rootfs — root is unlocked before
# switch-root. dracut does not copy drop-ins for generator-created units on its own, so
# elements/core/initramfs.bst names this path in install_items+=. Being staged in the
# rootfs alone would be invisible.
#
# See docs/skills/fido2.md § gpt-auto-generator owns the root's crypt options, and #250.
kind: manual

depends:
- freedesktop-sdk.bst:public-stacks/runtime-minimal.bst

variables:
  strip-binaries: ''

config:
  strip-commands:
  - ':'

  install-commands:
  - |
    install -Dm644 50-krytis-fido2-root.conf \
        "%{install-root}%{indep-libdir}/systemd/system/systemd-cryptsetup@root.service.d/50-krytis-fido2-root.conf"
  - "%{install-extra}"

sources:
- kind: local
  path: files/fido2-root-unlock
