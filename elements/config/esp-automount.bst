# esp-automount.bst: mount the ESP on a LUKS root, as systemd-gpt-auto-generator does
# on a plain one (#1328).
#
# On an encrypted install gpt-auto never generates the ESP automount: bootc points
# /run/systemd/volatile-root at the dm-crypt mapping, and systemd's blockdev_get_root()
# does not trace that back to the disk. systemd-boot-update.service then finds no ESP and
# the boot loader on it never updates. The generator writes gpt-auto's boot.mount and
# boot.automount for the LoaderDevicePartUUID partition, and only when volatile-root is a
# device-mapper device, so plain roots are untouched. The file carries the full reasoning;
# see docs/skills/secure-boot.md § The ESP's systemd-boot is updated by systemd, not
# bootc. `mise run esp-update-test` is the regression gate.
#
# Root filesystem only: gpt-auto mounts the ESP only after switch-root, and the generator
# exits in the initrd, so nothing here needs to reach dracut.
kind: manual

depends:
- freedesktop-sdk.bst:public-stacks/runtime-gnu.bst

variables:
  strip-binaries: ''

config:
  strip-commands:
  - ':'

  install-commands:
  - |
    install -Dm755 krytis-esp-automount-generator \
        "%{install-root}%{indep-libdir}/systemd/system-generators/krytis-esp-automount-generator"

sources:
- kind: local
  path: files/esp-automount
