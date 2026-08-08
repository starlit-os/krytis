# fido2-root-unlock.bst: make the ROOT volume attempt FIDO2 unlock.
#
# The baked karg rd.luks.options=fido2-device=auto does not reach the root volume:
# systemd-gpt-auto-generator creates that unit and builds its own option string,
# ignoring the karg entirely. Verified on hardware — the boot log showed only
# "No valid TPM2 token data found" and no FIDO2 attempt at all, with the karg present
# on /proc/cmdline throughout.
#
# Ships two files, and the split is the whole design:
#
#   krytis-fido2-root-unlock.service   tries FIDO2 BEFORE the generated unit, with an
#                                      ExecStart `-` prefix so failure is ignored
#   50-krytis-fido2-root.conf          a one-line condition skipping the generated
#                                      unit when that attempt already won
#
# Nothing overrides the generated ExecStart. An earlier version of this change did, and
# mise run luks-boot-test caught the regression: a missing FIDO2 token in the header is
# FATAL (-ENXIO), not a fall-through like TPM2, so putting fido2-device=auto in the
# root's options turned the passphrase prompt into emergency mode on every machine
# without an enrolled key. The files carry the full reasoning.
#
# Both must reach the INITRD, not just the rootfs — root is unlocked before
# switch-root. dracut does not copy drop-ins or extra units for generator-created units
# on its own, so elements/core/initramfs.bst names both paths in install_items+=. Being
# staged in the rootfs alone would be invisible.
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

    install -Dm644 krytis-fido2-root-unlock.service \
        "%{install-root}%{indep-libdir}/systemd/system/krytis-fido2-root-unlock.service"
  - "%{install-extra}"

sources:
- kind: local
  path: files/fido2-root-unlock
