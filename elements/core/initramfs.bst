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
  # plymouth-theme must be staged here too: dracut's plymouth module only
  # packages the theme currently selected in /etc/plymouth/plymouthd.conf,
  # so this sandbox needs Theme=spinner present before dracut runs below,
  # matching what stacks/desktop.bst sets on the final rootfs.
  - config/plymouth-theme.bst

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

      # tpm2-tss is NOT optional here despite nothing in the initrd linking it.
      # dracut's 73tpm2-tss module ends its check() with `return 255` — "include
      # only if another module requires it" — and nothing does, so it is omitted.
      # The TPM *kernel driver* still gets in, and that combination bricks any
      # machine that has a TPM: systemd-stub measures the UKI, so
      # systemd-pcrphase-initrd's ConditionSecurity=measured-uki SUCCEEDS, then
      # systemd-pcrextend dies on the missing TCTI, and that unit carries
      # FailureAction=reboot-force, so the machine reboot-loops. See #466.
      #
      # Naming the module in add_dracutmodules was NOT sufficient. 73tpm2-tss pulls
      # its TCTI libraries with inst_libdir_file, which searches dracut's libdirs;
      # in this sandbox that missed %{libdir}, so the linked libraries (esys, mu,
      # rc, sys, tctildr — all ELF deps of the tpm2 binaries) landed while the
      # dlopen'ed modules did not. install_items takes an explicit path and errors
      # if it cannot install it, which is what we want: loud, not silent.
      printf 'reproducible=yes\nhostonly=no\ncompress=zstd\nadd_dracutmodules+=" ostree bootc plymouth tpm2-tss "\ninstall_items+=" %{libdir}/libtss2-tcti-device.so.0 "\n' \
        | tee "%{install-root}/usr/lib/dracut/dracut.conf.d/30-bootcrew-bootc-container-build.conf" \
             "/usr/lib/dracut/dracut.conf.d/30-bootcrew-bootc-container-build.conf"

      dracut --force "%{install-root}/usr/lib/modules/${KVER}/initramfs.img"

    - |
      # Assert the TPM userspace actually made it in. This bug shipped because
      # nothing checked the initrd's CONTENTS — dracut omitted a dlopen'ed library
      # without failing, every QEMU gate skipped the unit that needed it for want of
      # a TPM, and the first symptom was a physical machine reboot-looping (#466).
      # A build-time assertion is the cheapest place to catch it.
      KVER=$(find /usr/lib/modules -maxdepth 1 -mindepth 1 -type d | head -1 | xargs basename)
      IMG="%{install-root}/usr/lib/modules/${KVER}/initramfs.img"
      if ! lsinitrd "${IMG}" | grep -q 'libtss2-tcti-device\.so\.0'; then
        echo "ERROR: libtss2-tcti-device.so.0 is missing from the initramfs." >&2
        echo "       systemd-pcrextend dlopen()s it, and systemd-pcrphase-initrd" >&2
        echo "       carries FailureAction=reboot-force, so every TPM-equipped machine" >&2
        echo "       would reboot-loop on this image. See #466 and mise/tasks/tpm-boot-test." >&2
        exit 1
      fi
      echo "==> initramfs carries the TPM TCTI module"
