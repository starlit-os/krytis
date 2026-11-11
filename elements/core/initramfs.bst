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
  # systemd's clock epoch, 2026-11-11T00:00:00Z, for the initrd and the real
  # root. Without it, systemd sets the clock back to 2011 on every boot from
  # 2026-11-11 05:11:11 UTC. See the dracut step below, the Containerfile and
  # #1595. This value lasts until 2041-11-11 (15 years). Raise it well before
  # then, never above the build date.
  clock-epoch: '1794355200'

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

      # Libraries the boot path dlopen()s. dracut cannot see a dlopen, so each has to
      # be named explicitly or it is silently omitted — and the frozen UKI cmdline
      # then asks the initrd for a capability it does not have. Both entries below
      # were found on real hardware after shipping, not by any gate.
      #
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
      #
      # libfido2 is the same shape (#473). The cmdline carries
      # rd.luks.options=fido2-device=auto, so every LUKS unlock tries FIDO2 first,
      # and systemd reaches it by dlopen. Unlike the TCTI this one is not fatal —
      # cryptsetup.c returns EAGAIN, clears the FIDO2 args and falls through to a
      # passphrase — so the only symptom is that a documented, shipped feature
      # cannot work. Its ELF deps (libcbor, libcrypto, libudev, libz) resolve
      # automatically; only the dlopen'ed entry point needs naming.
      #
      # libcryptsetup-token-systemd-fido2.so is the THIRD instance, and libfido2
      # alone was necessary but not sufficient (#476 shipped the library and unlock
      # still failed on hardware). `systemd-cryptenroll --fido2-device=auto` writes a
      # LUKS2 JSON token, so at boot determine_token_type() detects TOKEN_FIDO2 and —
      # use_token_plugins() being true by default — unlock goes through
      # attach_luks2_by_fido2_via_plugin(), which dlopens this plugin out of
      # %{libdir}/cryptsetup/. dracut cannot see that dlopen either, so the whole
      # directory was absent from every initrd and the plugin path could never run:
      # no plugin, no libfido2 scan, no user-presence request, straight to passphrase.
      #
      # Its siblings libcryptsetup-token-systemd-tpm2.so and -pkcs11.so are equally
      # absent. They are NOT added here because nothing ships TPM-bound or PKCS#11
      # LUKS today; whichever lands first (#368 for TPM) must add its own plugin and
      # an assertion below, or it will fail exactly this way.
      #
      # The last TWO entries are not libraries: they are the unit and drop-in from
      # config/fido2-root-unlock.bst that make the root volume attempt FIDO2 unlock.
      # systemd-cryptsetup@root.service is created by systemd-gpt-auto-generator at boot,
      # and dracut copies neither extra units nor drop-ins for generator-created units,
      # so naming them here is the only way they reach the initrd — where they have to
      # be, since root is unlocked before switch-root. See #250.
      printf 'reproducible=yes\nhostonly=no\ncompress=zstd\nadd_dracutmodules+=" ostree bootc plymouth tpm2-tss "\ninstall_items+=" %{libdir}/libtss2-tcti-device.so.0 %{libdir}/libfido2.so.1 %{libdir}/cryptsetup/libcryptsetup-token-systemd-fido2.so %{indep-libdir}/systemd/system/krytis-fido2-root-unlock.service %{indep-libdir}/systemd/system/systemd-cryptsetup@root.service.d/50-krytis-fido2-root.conf "\n' \
        | tee "%{install-root}/usr/lib/dracut/dracut.conf.d/30-bootcrew-bootc-container-build.conf" \
             "/usr/lib/dracut/dracut.conf.d/30-bootcrew-bootc-container-build.conf"

      # Clock epoch (#1595). clock_apply_epoch() (systemd src/core/clock-warp.c)
      # takes the newest of three values as the epoch: the compiled-in
      # TIME_EPOCH, the mtime of /usr/lib/clock-epoch, and the mtime of
      # /var/lib/systemd/timesync/clock. If the RTC is more than 15 years past
      # that epoch, PID 1 sets the clock BACK to the epoch. TIME_EPOCH is
      # BuildStream's 2011-11-11 11:11:11, so from 2026-11-11 05:11:11 UTC every
      # boot came up in 2011. Flathub's GPG key then looked created in the
      # future, and the first-boot flatpak units failed with "GPGME: No data".
      #
      # PID 1 runs this check TWICE: in the initrd, and again on the real root
      # after switch-root. early_skip_setup_check() (src/core/main.c) treats
      # --switched-root as a fresh boot, so both runs may move the clock back.
      # Each run needs its own /usr/lib/clock-epoch:
      #   - the initrd's copy is added to the dracut image here;
      #   - the real root's copy is installed below, holding the epoch as text.
      #     BuildStream stages every artifact file at 2011, so its mtime can't
      #     be set here. The Containerfile `touch`es it to the value it holds.
      #     Shipping only the initrd copy was tried first, and the clock was
      #     still reset after switch-root.
      #
      # Both halves are needed. reproducible=yes makes dracut clamp every mtime
      # newer than SOURCE_DATE_EPOCH down to SOURCE_DATE_EPOCH, which is 2011 in
      # this sandbox. A 2026 clock-epoch would be pulled straight back to 2011.
      # Passing the same value as SOURCE_DATE_EPOCH keeps the file at the epoch.
      # Files staged from BuildStream artifacts keep their 2011 mtime. Files dracut
      # writes during the run, such as usr/lib/initrd-release, now clamp to this
      # epoch instead of to 2011. Nothing reads those mtimes. The image stays
      # reproducible because the value is a constant.
      echo %{clock-epoch} > /usr/lib/clock-epoch
      touch -m -d "@%{clock-epoch}" /usr/lib/clock-epoch
      cp /usr/lib/clock-epoch "%{install-root}/usr/lib/clock-epoch"
      SOURCE_DATE_EPOCH=%{clock-epoch} dracut --force \
        --install /usr/lib/clock-epoch \
        "%{install-root}/usr/lib/modules/${KVER}/initramfs.img"

    - |
      # Assert each dlopen'ed library actually landed. Both bugs this guards shipped
      # because nothing checked the initrd's CONTENTS: dracut omits a dlopen'ed
      # library without failing, no QEMU gate had the hardware to exercise the unit
      # that needed it, and the first symptom was a physical machine (#466 reboot
      # loop, #473 FIDO2 unlock that cannot work). A build-time assertion is the
      # cheapest place to catch the whole class.
      #
      # Add a line when naming a new dlopen'ed library above. Keep the consequence
      # in the message: an assertion that only says "missing" makes the next reader
      # guess whether it matters.
      KVER=$(find /usr/lib/modules -maxdepth 1 -mindepth 1 -type d | head -1 | xargs basename)
      IMG="%{install-root}/usr/lib/modules/${KVER}/initramfs.img"
      CONTENTS=$(lsinitrd "${IMG}")
      MISSING=0
      assert_lib() {
        if ! printf '%s\n' "${CONTENTS}" | grep -q "$1"; then
          echo "ERROR: $2 is missing from the initramfs." >&2
          echo "       $3" >&2
          MISSING=1
        fi
      }
      assert_lib 'libtss2-tcti-device\.so\.0' 'libtss2-tcti-device.so.0' \
        'systemd-pcrextend dlopen()s it, and systemd-pcrphase-initrd carries
       FailureAction=reboot-force, so every TPM-equipped machine would
       reboot-loop on this image. See #466 and mise/tasks/tpm-boot-test.'
      assert_lib 'libfido2\.so\.1' 'libfido2.so.1' \
        'systemd-cryptsetup dlopen()s it for fido2-device=auto, which the UKI
       cmdline always sets, so FIDO2 LUKS unlock silently cannot work and every
       unlock falls back to a passphrase. See #473 and mise/tasks/luks-install-test.'
      assert_lib 'libcryptsetup-token-systemd-fido2\.so' 'libcryptsetup-token-systemd-fido2.so' \
        'libcryptsetup dlopen()s it to service the LUKS2 FIDO2 token that
       systemd-cryptenroll writes, so without it attach_luks2_by_fido2_via_plugin()
       never runs: no scan, no touch request, straight to a passphrase. Having
       libfido2 present is not enough — this is what calls it. See #250.'
      assert_lib 'krytis-fido2-root-unlock\.service' 'krytis-fido2-root-unlock.service' \
        'the unit that attempts FIDO2 unlock before the generated one. Absent, the root
       unlocks with gpt-auto-generator options only — tpm2-device=auto and nothing else —
       so FIDO2 is never attempted no matter what rd.luks.options= says. Not a library,
       but it fails the same way: silently, with a passphrase fallback. See #250.'
      assert_lib '50-krytis-fido2-root\.conf' 'systemd-cryptsetup@root.service.d/50-krytis-fido2-root.conf' \
        'the drop-in carrying Wants= (which is what STARTS the unit above — Before= only
       orders) and the condition that skips the generated unlock once the FIDO2 attempt
       has attached the volume. Without it the FIDO2 unit never runs, and if it somehow
       did, the generated unit would attach a second time onto a name already in use and
       fail the boot into emergency. See #250 and config/fido2-root-unlock.bst.'
      [ "${MISSING}" -eq 0 ] || exit 1
      echo "==> initramfs carries every dlopen'ed library and unlock unit the boot path needs"

    - |
      # The clock epoch's value is its mtime, so being present isn't enough:
      # check the mtime that actually landed (#1595). lsinitrd --unpack drops
      # mtimes, so extract with cpio -m instead.
      KVER=$(find /usr/lib/modules -maxdepth 1 -mindepth 1 -type d | head -1 | xargs basename)
      IMG="%{install-root}/usr/lib/modules/${KVER}/initramfs.img"
      U=$(mktemp -d)
      (cd "${U}" && /usr/lib/dracut/skipcpio "${IMG}" | zstd -dc | cpio -idm --quiet usr/lib/clock-epoch)
      GOT=$(stat -c %Y "${U}/usr/lib/clock-epoch" 2>/dev/null || echo missing)
      rm -rf "${U}"
      if [ "${GOT}" != "%{clock-epoch}" ]; then
        echo "ERROR: the initramfs /usr/lib/clock-epoch mtime is ${GOT}, want %{clock-epoch}." >&2
        echo "       systemd in the initrd would fall back to its 2011 TIME_EPOCH and reset" >&2
        echo "       every boot's clock to 2011-11-11. See #1595." >&2
        exit 1
      fi
      echo "==> initramfs clock epoch is %{clock-epoch} ($(date -u -d @%{clock-epoch} +%F))"
