kind: script

build-depends:
  - freedesktop-sdk.bst:components/fakecap.bst
  - freedesktop-sdk.bst:vm/prepare-image.bst
  - stacks/base-system.bst
  - stacks/bootc.bst
  - core/os-release.bst
  - core/linux-cachyos.bst
  # Plymouth must be staged here so dracut's plymouth module can find
  # the binary and libraries when building the initramfs. The plymouth
  # dracut module is enabled via 30-bootcrew-bootc-container-build.conf.
  - freedesktop-sdk.bst:components/plymouth.bst

variables:
  uuidnamespace: 042dab3d-c024-448b-a70e-927daef22a59

environment:
  LD_PRELOAD: /usr/libexec/fakecap/fakecap.so
  FAKECAP_DB: /fakecap

config:
  commands:
    - mkdir -p /fakecap /tmp /var/tmp

    - |
      prepare-image.sh --noroot --noboot \
                       --seed "%{uuidnamespace}" >/dev/null

    - echo '%{libdir}' >/etc/ld.so.conf

    - |
      KVER=$(find /usr/lib/modules -maxdepth 1 -mindepth 1 -type d | head -1 | xargs basename)
      mkdir -p "%{install-root}/usr/lib/modules/${KVER}"
      mkdir -p "%{install-root}/usr/lib/dracut/dracut.conf.d"

      # dracut's bootc module uses systemdsystemunitdir to place the
      # bootc-root-setup.service wants symlink. Without this override it
      # lands at /initrd-root-fs.target.wants/ (initramfs root) instead of
      # /usr/lib/systemd/system/initrd-root-fs.target.wants/, making it
      # invisible to systemd — composefs never mounts and switch-root fails
      # with no init at /sysroot.
      printf 'systemdsystemconfdir=/etc/systemd/system\nsystemdsystemunitdir=/usr/lib/systemd/system\n' \
        | tee "%{install-root}/usr/lib/dracut/dracut.conf.d/30-bootcrew-fix-bootc-module.conf" \
             "/usr/lib/dracut/dracut.conf.d/30-bootcrew-fix-bootc-module.conf"

      printf 'reproducible=yes\nhostonly=no\ncompress=zstd\nadd_dracutmodules+=" ostree bootc plymouth "\n' \
        | tee "%{install-root}/usr/lib/dracut/dracut.conf.d/30-bootcrew-bootc-container-build.conf" \
             "/usr/lib/dracut/dracut.conf.d/30-bootcrew-bootc-container-build.conf"

      dracut --force "%{install-root}/usr/lib/modules/${KVER}/initramfs.img"
